# Rock performance on GCE: what configuration can buy without bigger machines

- **Status:** research. Nothing in here has been applied.
- **Date:** 2026-08-26
- **Scope:** `connect-srv-prod` (Rock 18.4.1.0), `connect-srv-test` (Rock 19.3.4.0 plus the `pr-*` fleet), Cloud SQL `connect-prod`, project `passioncitychurch-com`, zone `us-east1-d`
- **Constraints this was written under:** no VM resizing, no machine-type changes, no production reboot. Where a change would need one, it says so.

## Short answer

Yes. The two largest wins are configuration, both are in files this repo already owns, and
neither needs a VM reboot.

1. `RockWeb/web.config` ships with `debug="true"`. That disables ASP.NET bundling and
   minification, so Rock serves roughly **105 individual unminified JavaScript files** per page
   instead of 7 bundles. This affects **prod and staging equally** and is invisible to the 302
   measurement.
2. Nothing anywhere sets IIS idle timeout or start mode, so the **20-minute default** applies.
   Rock's cache is in-process, so an idle timeout throws away everything and the next visitor
   pays the full cold start.

Neither of these is a machine-size problem. Item 1 needs a Rock restart to take effect, which a
normal deploy already does. Item 2 needs an app pool recycle. Details and the caveats that make
item 1 dangerous if done carelessly are below.

The wider finding is that **Rock publishes an official production hosting guide and these servers
are not following it** (section 2.0). Idle timeout, start mode, recycling schedule, application
preload and IIS compression are all specified there, and all five are currently at IIS stock
defaults. Most of what this document recommends is not novel tuning — it is catching up to the
vendor's documented configuration.

---

## Addendum — authenticated measurements, 2026-08-26

Taken through an authenticated staff browser session against **`connect.passion.team`**, which is
the host staff actually use. It and `rock.passion.team` are two bindings onto one IIS site: same
Rock build (18.4.1.0), byte-identical `last-modified` on theme assets, same Cloudflare origin.

| Metric | `/staff/home`, authenticated |
|---|---|
| TTFB (server think) | **260ms** |
| Warm re-fetch (×3) | **131 / 131 / 141ms** |
| Full page load | **1,444ms** |
| Requests | 124 |
| Transferred | 3.26 MB |

**The server is not the bottleneck.** A 260ms TTFB dropping to ~131ms warm means Rock renders the
page quickly. The 1.4s is delivery weight, which is why a larger VM would not help — and answers
the question that prompted this document.

Where the weight sits:

| Item | Cost |
|---|---|
| Icon fonts (Tabler 847KB + FontAwesome light/regular/solid ~480KB) | **1,326 KB** — two complete icon sets |
| Obsidian ES modules | 40 files, 590 KB — loaded individually by design; `debug="false"` does **not** change this |
| `GetImage.ashx` | 42 requests, but **all Cloudflare `HIT`** at 16–62ms |
| Third-party embeds in Lava | `calendar.google.com` 878ms, `api.open-meteo.com` 617ms |

**A per-hostname caching trap worth recording.** The same `GetImage.ashx` requests are
`cf-cache-status: HIT` on `connect.passion.team` with cache ages of 8.8 to 36.8 days, and `MISS` on
`rock.passion.team`. Cloudflare caches per hostname, so a low-traffic alias shows a cold edge while
the primary host is fully warm. Measuring the alias produced a false "Cloudflare is not caching
Rock's images" conclusion that was retracted. Measure the host real users hit.

---

## 1. What the measurement shows, and what it does not

**Measured:** prod returns its unauthenticated 302 login redirect in 0.06–0.13s. Staging takes
60–105s to first byte for the same redirect, with no pending migrations.

### What it proves

Staging's worker process is cold and prod's is warm. That is the whole of it. The gap is
warm-vs-cold, and prod is warm only because real traffic keeps it that way.

It is specifically **not** a v18-vs-v19 difference. I diffed the `LogStartupMessage` call sites
between `passion-18.4.1` and `passion-19.3.4` and the startup stage list is identical. v19 does
not do more work at `Application_Start` than v18. Any claim that staging is slow *because* it is
v19 is wrong.

### What it does not prove

A 302 does not measure page rendering. `Rock/Web/UI/RockPage.cs:1022-1027`:

```csharp
var isCurrentPersonAuthorized = _pageCache.IsAuthorized( Authorization.VIEW, CurrentPerson );
if ( !isCurrentPersonAuthorized )
{
    Response.Redirect( RockPageHelper.GetLoginPageUrl( RequestContext ), false );
    Context.ApplicationInstance.CompleteRequest();
}
```

`CompleteRequest()` short-circuits the pipeline. Nothing downstream runs. So the 0.06s number
excludes every part of Rock that a signed-in user actually waits on:

- No blocks load, so no block Lava renders and no Obsidian block bundles are resolved.
- No HTML body is produced, so **no JavaScript or CSS is requested at all** — the entire
  bundling problem in section 2.4 is invisible to this measurement.
- The authorization check hits cache, so no meaningful Cloud SQL query is issued.

**The report that both prod and staging feel slow is not contradicted by prod's fast 302.** They
measure different things. Prod being fast at 0.06s and slow to render an authenticated page are
compatible, and the `debug="true"` finding predicts exactly that pattern.

### A number that does not reconcile

The brief states a cold start takes ~6 minutes after a VM restart.
`Documentation/Training/DevOps-Open-Items-Rock-CICD.md` open item 20 records measurements of
**95s and 107s** for the first request after a VM restart, and 62.2s for a pr-4 site idle ~32
minutes. Those are not the same figure.

I could not resolve this from the repo. Possible explanations: the ~6 minutes includes Windows
boot and IIS service start before the first request is even accepted; or it includes the deploy
health check window; or a v19 migration run was counted. **This matters** — it decides whether
Rock's start fits inside IIS's 90-second `startupTimeLimit` (section 2.2). Treat 95–107s as the
measured application start and ~6 minutes as unverified until someone times it against
`App_Data\Logs\RockApplication.csv` on the box.

---

## 2. Findings

### 2.0 Rock publishes an official hosting guide, and we are not following it

This reframes most of what follows, so it goes first.

**Source:** *Rock Solid Internal Hosting*, Version 18.0, last updated 2025-11-12 — current official
Rock documentation.
[Landing page](https://community.rockrms.com/documentation/Book/1) ·
[PDF](https://rockrms.blob.core.windows.net/documentation/PDFs/72df0ea77f6d4e97a31ba101f36ed7c2_RockSolidInternalHosting.pdf)

Rock's own production build instructions, quoted:

| Rock's official instruction | Our state |
|---|---|
| "change the Start Mode to Always Running" | Not set — default `OnDemand` |
| "change Idle Time-out (minutes) to 0" | Not set — default 20 minutes |
| "Un-check Regular Time Intervals", set a specific daily restart time instead (their example: 4:00am) | Not set — default 29-hour drift |
| Enable the Windows **Application Initialization** feature, then set site-level **Preload Enabled = True** | Unknown; nothing in repo sets it |
| Enable IIS **dynamic content compression** | Unknown; nothing in repo sets it |
| "We recommend enabling snapshot isolation for your Rock database" | Unknown |

The guide also notes: *"You must enable Rock's 'Keep Alive' process, this is disabled by default.
This setting is not needed if your AppPool's Idle Time-out is set to 0 — which is highly
recommended."*

**This changes the risk calculus for recommendations 4 through 8 substantially.** They are not
clever ideas we invented and need to prove from first principles. They are Rock's documented,
supported production configuration, and these servers are running IIS stock defaults instead.
The burden of proof shifts: the question is no longer "is this safe to try" but "why are we not
already doing what the vendor documents."

**One item in that guide to deliberately NOT follow.** It also says *"change Identity setting to
LocalSystem."* Microsoft's own processModel reference warns that `LocalSystem` "has extensive
privileges on the local computer and acts as the computer on the network" and states plainly:
**"It is a serious security risk to run an application pool using high-level user rights."** For a
church system holding personal and giving data, that trade is not worth making for zero
performance benefit. `ApplicationPoolIdentity` is the modern default and is what
`Ensure-AppPool` already configures. Leave it alone.

### 2.1 IIS app pool idle timeout and recycling

Confirmed from the IIS configuration reference. All of these live in **applicationHost.config**,
not in the site's web.config — the page states "You configure the `<processModel>` element at the
server level in the ApplicationHost.config file."
([processModel](https://learn.microsoft.com/en-us/iis/configuration/system.applicationhost/applicationpools/add/processmodel))

| Attribute | Documented default | What it does |
|---|---|---|
| `idleTimeout` | `00:20:00` | "Specifies how long (in minutes) a worker process should run idle if no new requests are received... After the allocated time passes, the worker process should request that it be shut down by the WWW service." Disable with `00:00:00`. |
| `idleTimeoutAction` | `Terminate` | `Terminate` kills the process. `Suspend` (IIS 8.5+) pages it to disk instead — "likely making the worker process available more quickly than if it had been previously terminated." |
| `startupTimeLimit` | `00:01:30` | "If the application pool does not startup within the **startupTimeLimit**, the worker process is terminated and the rapid-fail protection count is incremented." |
| `shutdownTimeLimit` | `00:01:30` | Grace period on recycle before W3SVC terminates the old worker. |
| `pingingEnabled` / `pingInterval` / `pingResponseTime` | `true` / `00:00:30` / `00:01:30` | Health pings. A worker that misses a ping response is terminated. |
| `maxProcesses` | `1` | Single worker. Relevant because Rock's cache is per-process (2.4). |

Recycling, from
[periodicRestart](https://learn.microsoft.com/en-us/iis/configuration/system.applicationhost/applicationpools/add/recycling/periodicrestart/):

| Attribute | Documented default | Note |
|---|---|---|
| `time` | `29:00:00` (29 hours) | This is what IIS Manager labels **Regular Time Interval (minutes)** and what the IIS 6 metabase called `PeriodicRestartTime`. The brief's `regularTimeInterval` is the same setting under its older name. |
| `memory`, `privateMemory`, `requests` | `0` (disabled) | Not in play. |
| `schedule` child element | none set | Fixed clock times, as an alternative to the interval. |

And from
[applicationPools/add](https://learn.microsoft.com/en-us/iis/configuration/system.applicationhost/applicationpools/add/):
`autoStart` defaults `true`, `queueLength` defaults `1000`, `managedPipelineMode` defaults
`Integrated`.

**Why the 29-hour default is worse than it looks for a church.** It is an interval, not a clock
time. A pool that starts Sunday 08:00 recycles Monday 13:00, then Tuesday 18:00, and so on — it
walks around the clock and will eventually land in the middle of a Sunday service. A fixed 03:00
`schedule` entry removes that entirely, and is what Rock's hosting guide instructs (section 2.0).

**Rock's guide carries a caveat worth honouring:** a fixed restart time that falls inside the
daylight-saving "spring forward" hour can cause a job to run twice. `03:00` is inside that window
in US Eastern. Prefer **`04:00:00`** — which is also the time Rock's own guide uses in its
example.

**Nothing in this repository sets any of these.** `Ensure-AppPool` at
`Deploy-RockEnvironment.ps1:551` sets only `managedRuntimeVersion` and
`processModel.identityType`. So the
defaults above are what both boxes are running, unless someone set them by hand outside the
repo — which is one of the things section 4 says we cannot see from here.

One more attribute worth knowing before touching any of this: `disallowRotationOnConfigChange`
defaults to `false`, which means **editing app pool configuration recycles the pool**. There is
no way to change `idleTimeout` on prod without incurring one cold start.

### 2.2 IIS Application Initialization, preload, and warmup

From
[applicationInitialization](https://learn.microsoft.com/en-us/iis/configuration/system.webserver/applicationinitialization/).

**What it is.** "The `<applicationInitialization>` element specifies that web application
initialization is performed proactively before a request is received. An application can start up
more quickly if initialization sequences such as initializing connections, priming in-memory
caches, running queries, and compiling page code are performed before the HTTP request is
received."

The page is refreshingly honest about the mechanism, and it is worth repeating because it sets
expectations correctly: **"The application initialization does not necessarily make the
initialization process run any faster; it starts the process sooner."** This does not make Rock's
cold start shorter. It moves it off the critical path of a real person's request.

**Does it work on .NET Framework WebForms?** Yes. It is an IIS-level native module operating on
the application, not a framework feature, and `skipManagedModules` defaults to `false` meaning
managed modules *are* loaded during initialization. Rock is exactly the shape of app it was built
for. Introduced in **IIS 8.0**; not available on IIS 7.5 or earlier. Windows Server 2019/2022 run
IIS 10, so this is available on both boxes.

**Rock documents this as the supported production setup** — the hosting guide has admins install
the Application Initialization Windows feature and set site-level "Preload Enabled" to True
(section 2.0). So this is not an experimental idea; it is the configuration Rock expects a
production install to have.

**What it requires.** Three separate things, and missing any one produces no effect:

1. **The feature must be installed.** "To support application initialization on your Web server,
   you must install the Application Initialization role or feature." Server Manager → Web Server
   (IIS) → Web Server → Application Development → **Application Initialization**.
2. **`startMode="AlwaysRunning"`** on the app pool (section 2.3).
3. **`preloadEnabled="true"`** on the application.

The page states the dependency explicitly: "you can enable the initialization process to start
whenever the application pool is started. You do so by setting the **preLoadEnabled** attribute in
the `<application>` element to 'true'. **For this to occur, the start mode in the
`<applicationPool>` element must be set to AlwaysRunning.**"

**Config location.** "The `<applicationInitialization>` element is configured at the server, site,
or application level" — so it can go in `RockWeb/web.config`. `startMode` and `preloadEnabled`
cannot; see 2.3.

Two attributes to know:

- `doAppInitAfterRestart` (default `false`) — "Specifies that the initialization process is
  initiated automatically whenever an application restart occurs. **Note that this is different
  than the preLoadEnabled attribute**... which specifies that the initialization process is
  started after a restart of the application pool." Preload covers pool starts;
  `doAppInitAfterRestart` covers AppDomain restarts, which is what a deploy or a web.config write
  causes. For Rock you want both.
- `remapManagedRequestsTo` (default `""`) — serves a static holding page while the app warms
  instead of making the visitor wait. For a church site during a 95-second start, a "just a
  moment" page is a materially better experience than a stalled browser tab.

**Recycle, IIS restart, or reboot?** This is the distinction that matters most here:

| Action | What it disturbs |
|---|---|
| Installing the Application Initialization role service | Restarts the **WWW Publishing Service (W3SVC)**. Every site on that server drops for a few seconds. It does **not** require a VM reboot. Microsoft's page does not state the restart behaviour, so prove this on `connect-srv-test` before scheduling it for prod. |
| Editing `startMode` / `preloadEnabled` in applicationHost.config | **Recycles the affected app pool only.** No IIS restart, no reboot. |
| Editing `<applicationInitialization>` in `RockWeb/web.config` | **AppDomain restart of that application only.** No pool recycle, no IIS restart, no reboot. |

None of it needs a VM reboot. The feature install is the only step with blast radius beyond Rock
itself, and its radius is the other sites on the same box for a few seconds.

**The trap.** `startupTimeLimit` defaults to **90 seconds**, and the measured Rock start is
**95–107 seconds**. Those numbers are on the wrong side of each other. The Microsoft page defines
`startupTimeLimit` as "the time that IIS waits for an application pool to start" without settling
whether managed `Application_Start` counts against it — I could not find a primary source that
resolves this either way, so I am not going to assert it. The cheap answer is to raise
`startupTimeLimit` to `00:05:00` in the same change. It costs nothing if the concern is
unfounded, and it prevents a rapid-fail loop if it is not. **Prove this on staging first.**

### 2.3 `startMode="AlwaysRunning"` and `preloadEnabled`

**Exact locations.** Both are applicationHost.config-only. Neither can be set from the site's
web.config, which is the single most common reason people believe they enabled this and saw
nothing.

- `startMode` is an attribute of `<add>` under `system.applicationHost/applicationPools`. The
  reference states "The `<add>` element of the `<applicationPools>` collection is configurable at
  the server level in the ApplicationHost.config file."
- `preloadEnabled` is an attribute of `<application>` under `system.applicationHost/sites`, which
  is likewise an applicationHost.config-only section.

**Semantics, and they are not the same thing.** `startMode="AlwaysRunning"` (default `OnDemand`,
added IIS 7.5) means "the Windows Process Activation Service (WAS) will always start the
application pool. This behavior allows an application to load the operating environment before any
serving any HTTP requests." Note *operating environment* — this starts the **worker process** and
loads the CLR. On its own it does **not** run Rock's `Application_Start`. `preloadEnabled="true"`
is what sends the synthetic request that drives the managed application through startup.

`AlwaysRunning` alone is close to useless for Rock, because the expensive part of Rock's start is
managed code, not process creation.

**Does `AlwaysRunning` override `idleTimeout`?** No Microsoft documentation I found says it does,
and they are described as independent settings in independent elements. Assume they are
independent and **set both**. Setting `startMode` and leaving `idleTimeout` at 20 minutes is a
plausible way to get a half-fixed system that still goes cold.

A documented alternative worth noting: the processModel page states "You can configure an idle
timeout action of suspend with the fake request of application initialization." Combining
`idleTimeoutAction="Suspend"` with preload is a lighter-touch option than disabling the idle
timeout outright if memory on the box turns out to be tight.

### 2.4 Rock-specific settings

#### The headline: `debug="true"` in web.config

`RockWeb/web.config:43`:

```xml
<compilation debug="true" targetFramework="4.7.2" numRecompilesBeforeAppRestart="100" maxBatchGeneratedFileSize="25000">
```

This line is **identical on `passion-18.4.1`, `passion-19.3.4`, and upstream `develop`**. There is
no web.config transform anywhere in the build, and `Deploy-RockEnvironment.ps1:245` preserves only
`web.ConnectionStrings.config` across deploys — web.config itself is overwritten from the build
artifact every time. `.github/workflows/production-deploy.yml:374` confirms prod builds from the
same `pr-test-artifact.yml` pipeline as the test fleet. **So prod is running `debug="true"`.**

Microsoft's
[bundling and minification](https://learn.microsoft.com/en-us/aspnet/mvc/overview/performance/bundling-and-minification)
guidance is that bundling and minification are disabled in debug mode and enabled in release mode.
`RockWeb/App_Code/BundleConfig.cs` never sets `BundleTable.EnableOptimizations`, so there is no
override — the behaviour follows `<compilation debug>` directly.

What that costs: `BundleConfig.cs` declares 7 bundles containing 32 explicitly named files plus
wildcards. `~/Scripts/Rock/Controls/*.js` alone expands to 59 files; summernote plugins add 8;
Extensions, Validate and Admin add 6 more. **Roughly 105 individual unminified JavaScript files
served per page instead of 7 minified bundles**, against a browser limit of about 6 concurrent
connections per host.

This is the finding that reconciles "prod's 302 is fast" with "prod feels slow." A 302 has no
body, so it downloads none of those files.

**The caveat that makes this dangerous to fix naively.** From
[HttpRuntimeSection.ExecutionTimeout](https://learn.microsoft.com/en-us/dotnet/api/system.web.configuration.httpruntimesection.executiontimeout):
`[ConfigurationProperty("executionTimeout", DefaultValue="00:01:50")]`, and the remarks state
**"The default is 110 seconds. This time-out applies only if the debug attribute in the
`<compilation>` element is set to `false`."**

`RockWeb/web.config:77-80` sets no `executionTimeout`. Therefore:

> Rock's cold start currently survives **only because** `debug="true"` disables the request
> timeout. Rock's measured start is 95–107 seconds. The default timeout is 110 seconds. Setting
> `debug="false"` on its own would put a multi-minute startup under a 110-second guillotine with
> roughly ten seconds of headroom.

**`debug="false"` must be applied together with an explicit `executionTimeout`.** Something like
`executionTimeout="600"` on the `<httpRuntime>` element. Shipping one without the other is how you
turn a performance fix into an outage.

Also worth knowing: `<deployment retail="true">` in machine.config is sometimes suggested as a way
to force release behaviour without editing web.config. Per Microsoft's own documentation of the
retail switch it does not change the request-timeout interaction described above, so it is not a
substitute for setting `executionTimeout`. It also would not survive a VM rebuild the way a repo
change does.

#### Cache: in-process only, which is why recycles hurt so much

`Rock/Web/Cache/RockCacheManager.cs:101`:

```csharp
var config = new ConfigurationBuilder( "InProcess" ).WithDictionaryHandle();
```

Every cached object lives in the worker process's heap. **Any app pool recycle, idle timeout, or
AppDomain restart discards all of it.** There is no external cache tier to fall back on, so the
recovery cost is a full rebuild from Cloud SQL. This is the mechanism that turns IIS's ordinary
20-minute idle default into a 60–105 second user-visible stall.

`RockWeb/web.config:166` sets `CacheManagerEnableStatistics` to `False`, which is correct for
production and matches Rock's documentation — the Admin Hero Guide states statistics are off by
default "to improve overall system performance." **Do not switch them on casually: doing so
restarts Rock.** The Cache Manager block confirms it in its own confirmation prompt ("Changing
this setting will cause Rock to restart"). The Cache Manager page
(Admin Tools › System Settings › Cache Manager) exposes clearing by tag or type and viewing
hit/miss statistics — but **no cache size or lifespan configuration**. There is no TTL knob to
tune there.

#### Redis is gone — do not plan around it

`Rock/Web/Cache/RockCache.cs:772`:

```csharp
[Obsolete( "No longer needed since we no longer support Redis." )]
[RockObsolete( "1.15" )]
public static bool IsEndPointAvailable( string socket, string password )
```

`Rock/SystemKey/SystemSetting.cs:147` carries the same `[RockObsolete("1.15")]` on
`REDIS_ENABLE_CACHE_CLUSTER` and `REDIS_ENDPOINT_LIST`; the only remaining reader is a v14
migration. **Redis-backed distributed caching is not an option on Rock 18 or 19.**

Rock announced this officially:
[Ending Support for the Redis Caching Backplane](https://community.rockrms.com/connect/ending-support-for-redis-caching-backplane)
(2023-08-31) — *"Starting with Rock v17, we're removing support for the original Redis
backplane."* Deprecation was signalled earlier, in the Hyper Scaling Rock RMS guide: *"Support for
Redis clusters is deprecated as of Rock v13."*

**A versioning trap for anyone re-researching this:** `[RockObsolete("1.15")]` is Rock's *internal
library* version tag, a separate numbering track from the public v17/v18/v19 product version. It
does **not** mean "removed in v15." The Connect post's "Starting with Rock v17" is the
authoritative claim.

Rock Web Farm is not a substitute. It broadcasts cache *invalidation* over a message bus so each
node's independent in-process dictionary stays coherent — it is not a shared cache store. It also
requires a paid Spark license key. For a single server it offers nothing.

#### Lava cache is hardcoded

`Rock/Lava/WebsiteLavaTemplateCacheService.cs:39`:

```csharp
WebsiteLavaTemplateCache.DefaultLifespan = TimeSpan.FromMinutes( 10 );
```

Not configurable. There is no Lava cache tuning knob to reach for.

#### Block output caching is disabled in code

`RockWeb/Blocks/Core/BlockProperties.ascx.cs:532`:

```csharp
block.OutputCacheDuration = 0; //Int32.Parse( tbCacheDuration.Text );
```

The generic per-block output cache duration is hardcoded to zero with the real parse commented
out. The admin UI field exists but does nothing. **Do not plan on per-block output caching as a
tuning lever** — it is inert on both versions.

#### What actually happens at startup

`Rock.WebStartup/RockApplicationStartupHelper.cs` — `RunApplicationStartup()` at line 103,
`RunApplicationStartupStage1()` at 209. Notable costs:

- `HasPendingEFMigrations()` at line 644 reflects over and `Activator.CreateInstance`s **every**
  migration type on every single start. That is **1424 types on 18.4.1 and 1554 on 19.3.4**, paid
  in full even when there is nothing to migrate. This is why "no pending migrations" does not mean
  "fast start."
- `InitializeQueryableAttributeValues` creates SQL views; `RockCache.ClearAllCachedItems( false )`;
  `LoadEarlyCacheObjects`; `RockMessageBus.StartAsync().Wait()` (blocking); `InitializeLava`;
  `AISkillService.RegisterSkills`; Automation; `UpdateThemes`.

And `RockWeb/App_Code/Global.asax.cs` shows that startup is not over when `Application_Start`
returns:

- Line 217: `Task.Run( () => WarmupCache() );` — Rock already warms `EntityTypeCache`,
  `FieldTypeCache`, `AttributeCache`, `GroupTypeCache`, `BlockTypeCache`, `BlockCache`,
  `DefinedTypeCache`, `DefinedValueCache` and `CategoryCache` on a background thread. Its own
  comment says this "ensures that if Rock starts up without a request coming in that many things
  will be in cache already before the first request comes in." **That is precisely the scenario
  IIS preload creates.** Rock is already built for it; nothing is currently triggering it.
- Lines 245–251 then start `StartBlockTypeCompilationThread()`,
  `StartWorkflowActionUpdateAttributesThread()`, `StartCompileThemesThread()` and
  `StartEnsureChromeEngineThread()`. Block type compilation runs at
  `ThreadPriority.BelowNormal` and compiles every block type that is actually in use
  (`Global.asax.cs:412-418`).

So for some window **after** the app reports started, real requests compete with block-type
compilation and theme compilation for CPU. This is a second, independent reason the first few
authenticated page loads after any recycle feel bad, and another argument for warming the app
before people arrive rather than during.

`LogStartupMessage` (≈ line 1441 of `RockApplicationStartupHelper.cs`) appends to
`App_Data\Logs\RockApplication.csv`. **That file is the on-box ground truth for how long startup
actually takes** and would settle the 6-minutes-vs-107-seconds question in section 1.
`ShowDebugTimingMessage` only emits when `HostingEnvironment.IsDevelopmentEnvironment`, so the
detailed per-stage timings are not available in production.

#### Connection pooling

`RockWeb/web.ConnectionStrings.config` sets `MultipleActiveResultSets=true`, `Encrypt=true`,
`Connection Timeout=30`. Grepping the whole repository, **`Min Pool Size`, `Max Pool Size` and
`Pooling` are set nowhere**, so ADO.NET defaults apply: pooling on, min 0, max 100.

Per
[SQL Server connection pooling](https://learn.microsoft.com/en-us/dotnet/framework/data/adonet/sql-server-connection-pooling),
pools are per-process and per-connection-string, and the pooler removes connections idle for
roughly 4–8 minutes. With `Min Pool Size` unset, a freshly recycled Rock builds every connection
from scratch — TCP plus TLS plus SQL login, against a Cloud SQL instance rather than a local
socket. A modest `Min Pool Size` shaves the ramp after each recycle. It is a small win, not a
large one, but note this file **is** in `$PreservedFiles` (`Deploy-RockEnvironment.ps1:245`), so
unlike web.config a change here survives deploys.

#### One setting to leave alone, and why

- `RockWeb/web.config:120` — `<modules runAllManagedModulesForAllRequests="true">`. This routes
  every request, including static images/CSS/JS, through the full managed module pipeline. With
  ~105 unbundled scripts per page it compounds the bundling problem badly. Note this is a
  deliberate **deviation from the IIS default**, which is `false`
  ([modules reference](https://learn.microsoft.com/en-us/iis/configuration/system.webServer/modules/)).
  **But Rock relies on managed modules for its own routing**, and this is how Rock ships upstream.
  Fixing the bundling removes most of the harm without the risk. Do not touch this one
  speculatively.

#### `RunJobsInIISContext=False` — not a performance issue, but read this anyway

`RockWeb/web.config:160` — `<add key="RunJobsInIISContext" value="False" />`.

`Global.asax.cs:222-230` gates the entire Quartz scheduler behind this flag. When it is false,
`ServiceJobService.StartQuartzScheduler()` is never called.
`Rock.Migrations/RockStartup/DataMigrationsStartup.cs:151-171` gates post-update data migration
jobs the same way, and its engineering comment explains the intent: in a web farm exactly one node
should have it true, so jobs do not run twice.

There is **no alternative first-party job runner in the Rock codebase** — no standalone Windows
Service project exists for the scheduler. (`Rock.CloudPrint.Service` is unrelated.) So on a
single-server install with this left at `False`:

> **Scheduled jobs do not run. At all.** Not "less efficiently" — the scheduler never starts.

**Measured 2026-08-26, and this conclusion does not hold for prod.** Queried live against
production through Rock's own REST API (`/api/ServiceJobs`) using an authenticated staff session,
read-only:

- 153 jobs defined, **104 active**
- **Every active job reports `LastStatus: Success`**
- Most recent successful run: **within the same hour**
- Jobs that have never succeeded: **0**
- Rock's own `Job Pulse` heartbeat job is among those running

So the Quartz scheduler *is* running on production. The source reading above is correct about what
the flag does; the inference that prod inherits `False` from the artifact is what fails. Two
explanations survive, and they were not distinguished from off-box:

1. Prod's deployed `web.config` has `True` and has drifted from this repo, or
2. Rock's standalone Job Scheduler Windows Service is installed on `connect-srv-prod`. It exists
   as a first-party external app — `.github/CONTRIBUTING.md:293` lists "Job Scheduler Service"
   alongside Check Scanner and the Check-in Client — it just is not in this repository, so a
   repo-only search cannot see it.

**This matters for the v19 cutover, which is the reason to keep reading.** Under explanation 2
there is a second deployable on that box running its own copy of the Rock assemblies against the
same database. Upgrading RockWeb to 19.3.4 without upgrading that service leaves v18 job code
executing against a v19 schema. Establish which explanation is true before the cutover, not
during it.

There is no official Rock prose documentation for this setting anywhere — a full-text search of
the current 269-page Admin Hero Guide returns zero hits for `RunJobsInIISContext`, "job scheduler"
and "Windows Service". The above is derived from source, and is labelled as such deliberately.

#### One admin-UI trap

`Rock.Blocks/Administration/SystemConfiguration.cs:715` calls
`config.Save( ConfigurationSaveMode.Modified )` — the System Configuration block writes directly
to web.config. Since deploys overwrite web.config, **any change made through that admin page is
silently reverted by the next deploy.** Anything intended to be permanent has to be a repo change.
Note also that `SaveTimeout` at line 405 only edits the forms-authentication cookie timeout, not
`executionTimeout`, so the admin UI cannot make the change section 2.4 requires.

The exception is observability: `SaveObservabilityConfiguration` (lines 626–650) ends with
`ObservabilityHelper.ReconfigureObservability()`, which **takes effect live with no restart of any
kind**. That makes it the one safe thing that can be done to prod today.

#### Does Rock say anything official about `debug="true"`?

**No.** There is no official Rock statement anywhere instructing admins to set `debug="false"` in
production, and no `debug="false"` appears anywhere in the repository. There is also no
`Web.Release.config` / `Web.Debug.config` XDT transform in the tree, so there is no build-time
mechanism that would flip it.

**One caveat that has to stay open.** The official install flow has the bootstrap installer
download the RockWeb payload from the same source, which is consistent with the shipped file being
unchanged — but the actual downloadable installer artifact sits behind a community.rockrms.com
login, and Rock does not publish binaries via GitHub Releases. **Nobody has read the literal
shipped installer's web.config.** Strong circumstantial evidence, not certainty. Verify against a
real production install before relying on it (section 4).

Microsoft's own troubleshooting article
([Debug mode in ASP.NET applications](https://learn.microsoft.com/en-us/troubleshoot/developer/webapps/aspnet/performance/debug-mode-applications))
independently confirms the timeout analysis above: under `debug="true"` the execution timeout is
extended to **30,000,000 seconds**, which is what "effectively disabled" means in practice. It
states plainly: *"It is recommended that debug mode is always disabled in a production
environment."* The ASP.NET deployment guidance is blunter:
*"You should **never** have the `debug` attribute set to 'true' in a production environment
because of its impact on performance."*
([Common Configuration Differences Between Development and Production](https://learn.microsoft.com/en-us/aspnet/web-forms/overview/older-versions-getting-started/deploying-web-site-projects/common-configuration-differences-between-development-and-production-cs))

So: two independent Microsoft sources say do not do this, Rock ships it anyway, and Rock's own
documentation is silent on it.

### 2.5 Cloud SQL

Google's own recommendation, from
[Cloud SQL for SQL Server connection overview](https://docs.cloud.google.com/sql/docs/sqlserver/connect-overview):

- "A direct connection from a client to a Cloud SQL instance provides a lower latency connection."
- "If you're connecting to an instance by a private IP address, use a direct connection."
- Direct connections have "Lower latency compared to connections using Cloud SQL connectors."

So: **private IP with a direct connection is Google's documented lowest-latency option**, and the
Cloud SQL Auth Proxy — being a connector — is documented as adding latency relative to that. The
Auth Proxy exists to solve authentication and encryption for public-IP scenarios, which is a
different problem than the one we have when both sides are in the same VPC.

Whether Rock currently connects over private IP or via the proxy is in
`web.ConnectionStrings.config` on each box, which is `.gitignore`d and not visible from here
(section 4). **If it is going through the Auth Proxy on a private-IP-reachable instance, removing
that hop is a real and safe latency win with no restart of Rock required beyond the connection
string change.**

**Same-zone placement matters** in the ordinary sense that cross-zone traffic crosses more
network. Both VMs and the instance are stated to be in `us-east1-d`, so this is already right and
there is nothing to gain here.

**SQL Server 2019 Web edition caps are the thing to know before anyone proposes a bigger Cloud SQL
instance.** From
[Editions and supported features of SQL Server 2019](https://learn.microsoft.com/en-us/sql/sql-server/editions-and-components-of-sql-server-2019):

| Limit | Web edition |
|---|---|
| Maximum compute capacity, single instance | "Limited to lesser of 4 sockets or 16 cores" |
| Maximum buffer pool memory per instance | **64 GB** |
| Maximum relational database size | 524 PB (not a constraint) |
| Batch mode DOP | Limited to **1** for Web and Express editions |
| Batch mode on rowstore | Enterprise only |
| Resource governor, read-ahead, advanced scanning, automatic tuning | Enterprise only |

**Cores beyond 16 and memory beyond roughly 64 GB of buffer pool are wasted spend on this
edition.** That is a useful thing to be able to say out loud the next time someone suggests the
answer is a bigger database machine.

The genuinely valuable line in that table is a positive one: **Query Store is supported on Web
edition.** It is the supported, no-app-change way to find which authenticated queries are actually
slow. (SQL Profiler is *not* available on Web edition, so Query Store is the practical option.)
Enabling it is a database-level setting and requires no Rock restart.

**Snapshot isolation is Rock's one official database recommendation.** From the Rock Solid
Internal Hosting guide: *"We recommend enabling snapshot isolation for your Rock database. This
keeps database reads from being locked by database writes."* That is a read-contention fix, which
is exactly the class of problem that makes authenticated pages feel slow under concurrent load
while an unauthenticated 302 stays fast. Worth checking whether it is on. It is a database-level
setting requiring no Rock restart, though enabling it on a busy database needs a quiet moment to
acquire the lock.

**What Rock explicitly does not document:** a full-text search of the 53-page hosting guide finds
**no mention of MAXDOP, database compatibility level, or recovery model.** If someone proposes
tuning those, there is no official Rock guidance backing it either way. Say so rather than
inventing a recommendation.

Cloud SQL database flags for SQL Server are a narrower set than for MySQL or Postgres, and I did
not find a flag that plausibly addresses a 95-second application start — because that start is
CPU and reflection bound in the web tier, not database bound. **Do not go looking for the answer
in Cloud SQL flags.** Once Query Store shows which authenticated queries are slow, revisit.

### 2.6 GCE settings that do not involve resizing

These are real but secondary. Nothing here explains a 95-second managed-code startup.

| Lever | Effect | Requires stop/start? |
|---|---|---|
| Persistent disk **type** (pd-standard → pd-balanced → pd-ssd) | Per-GiB IOPS and throughput scale with both type and provisioned size. Matters for the many-small-file reads that an unbundled `~105 JS files` page produces, and for IIS/ASP.NET temp compilation. | Changing type generally requires recreating or migrating the disk. **Out of scope for prod.** |
| Persistent disk **size** increase | IOPS scale with provisioned size on Google's PD model, so growing a disk raises its ceiling. | Growing a disk can be done **live**; the filesystem extend is an in-guest operation. This is the one disk lever available without a prod restart. |
| Network Service Tier: Standard → **Premium** | Premium routes over Google's backbone for more of the path rather than exiting to the public internet near the client. Affects client-to-VM latency, not VM-to-Cloud-SQL. | Changing the tier on an existing external address generally requires the address/instance to be reconfigured. **Verify before scheduling; likely a stop/start.** |
| **Tier_1 networking** / gVNIC | Higher egress bandwidth caps. Irrelevant here — this workload is not bandwidth-bound. | Requires stop/start, and gVNIC requires a supported guest driver. Not worth it. |

The honest summary of 2.6: **for the problem actually being reported, GCE-side settings are the
least productive place to look.** Increasing disk size is the only lever here that is both live
and plausibly useful, and its effect is modest compared to sections 2.1–2.4.

---

## 3. Ranked recommendations

Ranked by value-per-unit-of-risk, not by raw value. The first two are deliberately the ones that
cost nothing and tell us whether the rest are aimed correctly.

"Recycle" means the Rock app pool restarts and Rock cold-starts (60–107s of degraded service).
"AppDomain restart" means the same user-visible cold start without IIS itself being touched. **No
recommendation in this table requires a VM reboot.**

| # | Change | Expected effect | Risk | Restart needed |
|---|---|---|---|---|
| 1 | **Enable Rock Observability** via the admin UI (`SaveObservabilityConfiguration` → `ReconfigureObservability()`) | None on speed. This is how we get real authenticated request timings instead of arguing about a 302. | **None.** Takes effect live. | **Nothing.** Safe on prod today. |
| 2 | **Enable Query Store** on Cloud SQL `connect-prod` | Identifies genuinely slow authenticated queries. Supported on Web edition; Profiler is not. | Low. Small write overhead. | **Nothing.** Database-level. |
| 3 | **`debug="false"` + explicit `executionTimeout="600"`** in `RockWeb/web.config` | Real, but smaller than first estimated — see the 2026-08-26 addendum. Bundling is already happening in production (live bundle URLs observed). What `debug="true"` actually costs is **minification**: a 414KB bundle served at 45 chars/line, and `MicrosoftAjax.debug.js` at 320KB where the release build is roughly 100KB. Expect to recover 400–500KB of a 3.26MB page, not to collapse the request count. The 40 Obsidian ES modules are unaffected. Applies to **both** boxes. | **Medium, and asymmetric.** Safe if applied as a pair. Shipping `debug="false"` *without* `executionTimeout` puts a 95–107s startup under a 110s timeout. | **AppDomain restart.** Rides along free with an already-planned deploy, since deploys overwrite web.config and restart Rock anyway. |
| 4 | **`idleTimeout="00:00:00"`** on the Rock app pool (applicationHost.config) | Removes the 20-minute cold-start cliff entirely. Fixes staging outright; protects prod on quiet weeknights. | **Low — this is Rock's documented production setting** ("change Idle Time-out (minutes) to 0"). Memory stays resident; confirm headroom first. | **Pool recycle** (`disallowRotationOnConfigChange` defaults false). Free on staging; fold prod into a maintenance window. |
| 5 | **`periodicRestart`: clear `time`, add a `schedule` entry at `04:00:00`** | Stops the 29-hour drifting recycle from eventually landing mid-Sunday-service. | **Low — Rock's documented setting** ("Un-check Regular Time Intervals" + fixed daily time). Use 04:00, not 03:00: Rock warns a restart inside the DST spring-forward hour can run a job twice. | **Pool recycle** to apply. |
| 6 | **`startupTimeLimit="00:05:00"`** | Insurance. Prevents a rapid-fail loop if Rock's 95–107s start is counted against the 90s default. | Very low. Only extends a timeout. | **Pool recycle.** Apply in the same edit as #4 and #5. |
| 7 | **Application Initialization**: install the feature, then `startMode="AlwaysRunning"` + `preloadEnabled="true"` + `<applicationInitialization doAppInitAfterRestart="true">` | Rock's existing `WarmupCache()` and block-type compilation run *before* users arrive and after every recycle. Turns a 95s stall into a background event. | **Low–medium. All of this is Rock's documented production config** — the guide has admins install the Application Initialization feature and set Preload Enabled = True. The residual risk is operational (three-part dependency, all required), not architectural. Do #6 first. | **Feature install restarts W3SVC** (all sites on the box drop briefly) — no VM reboot. Config edits then only **recycle the pool**. **Prove the whole sequence on `connect-srv-test` first.** |
| 8 | **Enable IIS dynamic content compression** | Smaller HTML/JSON on the wire. Rock's hosting guide recommends it explicitly. | Low. Costs some CPU per response; standard practice. | **None to enable the feature if already installed**; otherwise the role-service install **restarts W3SVC**. |
| 9 | **Verify/enable snapshot isolation** on the Rock database | Rock's one official DB recommendation: "keeps database reads from being locked by database writes." Targets exactly the concurrency stall that makes authenticated pages slow while a 302 stays fast. | Low, but the `ALTER DATABASE` needs a quiet moment to take its lock. | **Nothing on the Rock side.** Database-level. |
| 10 | **`remapManagedRequestsTo`** a static holding page | During any unavoidable cold start, visitors get "just a moment" instead of a hung tab. | Low. | **AppDomain restart** (web.config). |
| 11 | **`Min Pool Size`** in `web.ConnectionStrings.config` | Modest. Removes connection-pool ramp after each recycle. Survives deploys (it is in `$PreservedFiles`). | Low. Holds idle connections against Cloud SQL's connection limit. | **AppDomain restart.** |
| 12 | **Verify Cloud SQL connection path**; move to private IP + direct connection if currently proxied | Per Google, direct-over-private-IP is the documented lowest-latency option. Real if the proxy is in the path; zero if it is not. | Low–medium. Requires confirming VPC reachability first. | **AppDomain restart** (connection string). |
| 13 | **Raise `$RecycleAfterSeconds`** from `240` in `Deploy-RockEnvironment.ps1:805` | Deploy correctness, not speed. 240s cuts off a legitimate 95–107s+ startup with too little margin, producing deploys that look failed but are not. | Low. | **None** — script change, applies next deploy. |
| 14 | **Grow the persistent disk** on `connect-srv-prod` | Modest. PD IOPS scale with provisioned size. Helps small-file reads and ASP.NET temp compilation. | Low. | **None** — disks grow live. Do this only after #3, which removes most of the small-file load. |

**Not on this list, and now partly resolved:** `RunJobsInIISContext=False` (section 2.4).
Live API evidence shows 104 active jobs all succeeding on prod, so the feared outage is not
happening. What remains open is *how* — a drifted `web.config` or a separate Job Scheduler
Windows Service — and that question is a **v19 cutover prerequisite**, because the second
explanation implies a second deployable that also needs upgrading. See section 2.4.

Suggested sequencing: **1, 2 and 9 immediately** (zero to near-zero risk, and 1 and 2 tell us
whether anything else is aimed correctly). **4, 5, 6, 7 and 8 on staging next** — these are
Rock's documented production configuration, staging is currently the worst-affected box, and a
recycle there costs nothing. Once proven on staging, they go to prod as one batched app pool
edit in a single maintenance window rather than five separate recycles. **3 folded into the next
planned prod deploy**, since that deploy already overwrites web.config and restarts Rock.
Everything else follows from what #1 and #2 actually measure.

---

## 4. What we cannot determine without getting onto the boxes

Each of these changes a recommendation above, and none is answerable from this repository.

**Actual IIS state.** The repo never sets `idleTimeout`, `startMode`, `preloadEnabled`,
`periodicRestart` or `startupTimeLimit`, and `Ensure-AppPool` sets only two unrelated properties —
so documented defaults are the *reasonable inference*, not an observation. Someone may have set
these by hand outside version control. **`appcmd list apppool "<name>" /text:*` settles it in one
command.** Likewise, whether the Application Initialization role service is already installed
(`Get-WindowsFeature Web-AppInit`) is unknown.

**Whether prod's deployed web.config actually matches the repo.** The deploy script's
`$PreservedFiles` list says it should, and `production-deploy.yml:374` says prod builds from the
same artifact. But the `debug="true"` recommendation rests on that inference. **Read the deployed
`RockWeb\web.config` on prod before changing anything.** If it already says `debug="false"`, the
top recommendation evaporates and the analysis needs revisiting.

**How long startup really takes.** 95–107s (measured, open item 20) versus ~6 minutes (stated in
the brief) is a 3× disagreement, and it decides whether the 90-second `startupTimeLimit` and the
110-second `executionTimeout` are near-misses or direct hits. `App_Data\Logs\RockApplication.csv`
on each box has the timestamps. This is the single highest-value thing to go read.

**Authenticated request timings.** Everything measured so far is a 302 that renders nothing. Until
someone times a real signed-in page — recommendation #1 makes this possible without box access —
the split between "slow because cold", "slow because 105 unbundled scripts", and "slow because of
a specific query" is unquantified. **I am confident about the mechanisms and not about their
relative sizes.**

**The Cloud SQL connection path.** `web.ConnectionStrings.config` is not in the repo. Private IP
versus public IP, Auth Proxy versus direct, and whether any pooling parameters were set by hand on
the box are all unknown. Recommendation #10 may already be done.

**Whether scheduled jobs run at all.** `RunJobsInIISContext` is `False` in the repo web.config,
which is overwritten every deploy. If no separate Rock Job Scheduler service exists on these
boxes, then neither scheduled jobs nor post-update data migration jobs are running. That is a
correctness question rather than a performance one, but it is worth confirming while someone is
already on the box.

**Memory headroom.** Recommendation #4 keeps the worker process resident indefinitely. That is
only safe if the box has the RAM. Nobody has looked.

**Whether the shipped installer's web.config matches the source.** The repo ships `debug="true"`
with no transform and no `debug="false"` anywhere, and the official install flow downloads the
same RockWeb payload — but the actual installer artifact is behind a community.rockrms.com login
and Rock publishes no GitHub Releases, so nobody has read the shipped file directly. This is the
one remaining open question behind recommendation #3, and reading prod's deployed web.config
answers it more directly than chasing the installer would.

**Whether IIS dynamic compression and snapshot isolation are already on.** Both are Rock's
official recommendations (section 2.0). Neither is visible from the repo. Both may already be
done, in which case recommendations #8 and #9 evaporate.

**Obsidian block performance.** No official Rock documentation exists on Obsidian bundling,
code-splitting, lazy-loading, or block-level performance tuning — only a developer note about the
`Obsidian.options.fingerprint` cache-busting override. This is a genuine documentation gap, not
something I failed to find. If Obsidian block rendering turns out to be a significant share of
authenticated page time once recommendation #1 is measuring, there is no vendor guidance to lean
on and it becomes original investigation.
