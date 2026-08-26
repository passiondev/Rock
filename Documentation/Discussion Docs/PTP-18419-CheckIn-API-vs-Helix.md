# PTP-18419 — Check-in: REST API vs. Helix (Lava Applications)

**Ticket:** PTP-18419 — *Understand the pros/cons of using API vs HELIX check-in approaches*
**Codebase:** this fork, branch `passion-19.3.4` (Rock v19.3.4)
**Written:** 2026-08-26
**Method:** primary sources = the source in this working copy, cited as `path:line`. Secondary sources = published Rock/Triumph documentation, labelled **[SECONDARY]** inline and listed at the end. Where the two disagree, the code wins. Git history is unreliable in this working copy (shallow checkout), so nothing here rests on `git log`; the two history-adjacent claims use tree queries (`git cat-file -e <ref>:<path>`), which are reliable.

---

## 1. Verdict / TL;DR

### 1.1 The disputed line

> *"Neither path lets you reach into Rock's check-in engine directly — that door is shut on both sides."*

**Bryson is right to push back. As written, the line is false and materially misleading.** It is true only of one narrow thing that almost nobody needs, and it is false about the thing the ticket actually asks about.

| Path | Verdict on the line | Why |
|---|---|---|
| **[1] API + plain HTML/JS** | **FALSE.** The door is wide open. | `Rock.Rest/v2/CheckInController.cs` exposes the entire check-in pipeline over HTTP — 11 endpoints, every one of them constructing `new CheckInDirector( _rockContext )` and delegating to the real engine. Rock's own shipped Next Gen kiosk uses **nothing but** these endpoints. The request/response DTOs are ordinary public types with **zero** `[RockInternal]` markings. |
| **[2] Helix / Lava Application** | **TRUE for in-process access; FALSE for "the door is shut."** | No Lava shortcode, command, or filter can call `CheckInDirector` in-process — the engine classes are C# `internal` and Lava is not on the `InternalsVisibleTo` list. But a Lava Endpoint can call the **same** REST API over HTTP with `{% webrequest %}`, and the page can call it with plain `fetch()`. Helix is a UI layer that consumes the API; it is not an alternative to the API. |
| **Narrow sense in which the line is true** | **TRUE.** | `CheckInDirector`, `CheckInSession` and every provider are declared `internal class`, and `Rock`'s `InternalsVisibleTo` list names only core Rock assemblies. No plugin DLL, no `{% execute %}` block, and no Helix endpoint can bind to those types by name. Rock's own WebForms code has to use reflection to get at one static method (see §2.6). |

**The most important structural correction:** the ticket frames options [1] and [2] as alternatives. They are not. **Helix still uses the API.** The real choice is *what renders the UI and where the orchestration lives* — client-side JS against JSON, or server-side Lava returning HTML fragments — not *whether you use the API*.

### 1.2 Recommendation

**A hybrid, with the REST API as the non-negotiable foundation.**

1. **All check-in engine work goes through `api/v2/checkin/*`.** There is no supported alternative and no reason to want one. This also inherits the "25× faster" Next Gen engine **[SECONDARY]** without reimplementing any of it.
2. **Host the UI in a Lava Application (Helix) page** if — and only if — the Lava-driven customization and supplemental fields are the actual requirement. That is exactly what Helix is good at, and it is the half of Bryson's instinct that is correct.
3. **Do the check-in call sequence from the browser with `fetch()`**, not with htmx attributes. htmx wants HTML back; the check-in API speaks JSON (§3.6). Use Lava Endpoints for the *supplemental* content — custom fields, campus-specific messaging, anything that needs to query Rock data the check-in DTOs don't carry.
4. **Printing must be `PrintFrom.Server` with a Cloud Print proxy.** This is forced, not chosen (§4). Budget for it as infrastructure work.
5. **Do not attempt to write attendance with `{% modifyattendance %}` or `{% sql %}`.** It is technically possible and it is a trap (§3.4).

**Honest caveat on effort:** neither option is small. The REST API covers the check-in *flow* but not family registration, supervisor mode, label reprint, room open/close, or live room counts — those live only in Obsidian block actions (§2.3). Any custom front-end either does without them or reimplements them.

**If forced to pick exactly one and ship it:** the pure-API path with a small JS front-end, because the printing story, the auth story, and the upgrade-risk story are all identical either way, and the API path has fewer moving parts and no dependency on a feature Rock's own docs still describe as beta in places **[SECONDARY]**. Choose Helix over that only if server-side Lava authorship by non-C# staff is a stated requirement rather than a preference.

---

## 2. Q1 — The API surface, and adjudicating the disputed claim

### 2.1 Complete endpoint inventory

`Rock.Rest/v2/CheckInController.cs:57` — `[RoutePrefix( "api/v2/checkin" )]`, class `public sealed class CheckInController : ApiControllerBase` with `[RestControllerGuid( "52b3c68a-da8d-4374-a199-8bc8368a22bc" )]`.

| Verb | Route | Attributes | Request → Response | Engine call |
|---|---|---|---|---|
| POST | `Configuration` | `[Authenticate]`, `[Secured(EXECUTE_READ)]` (`:87-94`) | `ConfigurationOptionsBag` → `ConfigurationResponseBag` | `new CheckInDirector(...)` `:97`; `GetConfigurationTemplateBags()`, `GetCheckInAreaSummaries( kiosk, null )` |
| POST | `KioskStatus` | `[Authenticate]`, `[Secured(EXECUTE_READ)]` (`:130-137`) | `KioskStatusOptionsBag` → `KioskStatusResponseBag` | `:140`; `director.GetKioskStatus( areas, kiosk, null )` |
| POST | `SearchForFamilies` | `[Authenticate]`, `[Secured(EXECUTE_READ)]` (`:176-183`) | `SearchForFamiliesOptionsBag` → `SearchForFamiliesResponseBag` | `:213`; `director.CreateSession(...)` → `session.SearchForFamilies( term, searchType, sortByCampus )` |
| POST | `FamilyMembers` | `[Authenticate]`, `[Secured(EXECUTE_READ)]` (`:235-242`) | `FamilyMembersOptionsBag` → `FamilyMembersResponseBag` | `:261`; `session.LoadAndPrepareAttendeesForFamily(...)`, `GetAttendeeBags()`, `GetAllPossibleScheduleBags()`, `GetCurrentAttendanceBags(...)`, `director.TryAuthenticatePin(...)` |
| POST | `AttendeeOpportunities` | `[Authenticate]`, `[Secured(EXECUTE_READ)]` (`:297-304`) | `AttendeeOpportunitiesOptionsBag` → `AttendeeOpportunitiesResponseBag` | `:323`; `session.LoadAndPrepareAttendeesForPerson(...)`, `session.GetOpportunityCollectionBag(...)` |
| POST | `SaveAttendance` | `[Authenticate]`, `[Secured(EXECUTE_WRITE)]` (`:361-369`) | `SaveAttendanceOptionsBag` → `SaveAttendanceResponseBag` | `:391`; `session.SaveAttendance(...)` then `director.LabelProvider.RenderAndPrintCheckInLabelsAsync(...)` |
| POST | `ConfirmAttendance` | `[Authenticate]`, `[Secured(EXECUTE_WRITE)]` (`:431-439`) | `ConfirmAttendanceOptionsBag` → `ConfirmAttendanceResponseBag` | `:461`; `session.ConfirmAttendance( sessionGuid )` + label render/print |
| POST | `Checkout` | `[Authenticate]`, `[Secured(EXECUTE_WRITE)]` (`:496-504`) | `CheckoutOptionsBag` → `CheckoutResponseBag` | `:526`; `session.Checkout(...)` + `RenderAndPrintCheckoutLabelsAsync` |
| DELETE | `PendingAttendance/{sessionGuid}` | `[Authenticate]`, `[Secured(EXECUTE_WRITE)]` (`:548-555`) | route param → 200 | `:560`; `director.DeletePendingAttendance( sessionGuid )` |
| GET | `CloudPrint/{deviceId}` | **no `[Authenticate]`, no `[Secured]`** (`:579-584`) | `?name=` → 101 Switching Protocols | `:611`; `new CloudPrintSocket( ctx.WebSocket, device.Id, name, address )` |
| POST | `ProximityCheckIn` | `[Authenticate]`, **no `[Secured]`**; returns `Unauthorized()` when `RockRequestContext.CurrentPerson == null` (`:625-632`) | `ProximityCheckInOptionsBag` → `ProximityAttendanceNotificationBag` | `:659`; `new ProximityDirector(...)`, `.CheckIn(...)` / `.Checkout(...)` |

Permission constants: `Rock/Security/Authorization.cs:212` `EXECUTE_READ = "ExecuteRead"`, `:218` `EXECUTE_WRITE = "ExecuteWrite"`.

**[SECONDARY] corroboration:** all 11 of these appear as a first-class `api/v2/checkin` tag in Rock's officially linked v2 Swagger, on a demo instance running **v19.3.4 — the exact version of this branch** — each with an XML-doc summary and **no `deprecated` flag and no internal annotation**. That is publication in Rock's own documentation surface. It is *not* a stability promise; see §5.9.

### 2.2 Can plain HTML/JS drive a complete check-in? Yes — and here is the proof

The full flow is reachable end to end:

```
POST Configuration        → pick template + kiosk (returns ConfigurationTemplateBag[], area summaries)
POST KioskStatus          → is the kiosk open, when does it open/close
POST SearchForFamilies    → phone / name / scanned ID / family id  (FamilySearchMode)
POST FamilyMembers        → attendees, possible schedules, current attendance
POST AttendeeOpportunities→ areas / groups / locations / schedules / ability levels for one person
POST SaveAttendance       → writes attendance, prints server labels, RETURNS client labels
    ├─ POST ConfirmAttendance              (when the session was pending)
    ├─ DELETE PendingAttendance/{guid}     (abandon)
    └─ POST Checkout
```

**The decisive evidence is that this is exactly what Rock's own Next Gen kiosk does, and it does nothing else.** The shipped Obsidian kiosk is a REST client:

- `Rock.JavaScript.Obsidian.Blocks/src/CheckIn/CheckInKiosk/checkInSession.partial.ts` calls `SaveAttendance` (`:371`), `ConfirmAttendance` (`:412`), `SearchForFamilies` (`:491`), `FamilyMembers` (`:525`), `Checkout` (`:587`), `AttendeeOpportunities` (`:835`), and `DELETE pendingAttendance/${sessionGuid}` (`:1506`).
- `Rock.JavaScript.Obsidian.Blocks/src/CheckIn/checkInKiosk.obs:460` uses a **bare `fetch()`** against `/api/v2/checkin/Configuration` as a "is Rock back up yet" heartbeat — no Obsidian machinery at all.
- `Rock.JavaScript.Obsidian.Blocks/src/CheckIn/Configuration/checkInSimulator.obs` (`:314, :357, :405, :518, :550`) hits the same routes.

If a plain `fetch()` from Rock's own kiosk works, a plain `fetch()` from your HTML works. There is no privileged channel.

**The API is deliberately stateless, which is what makes a thin client viable.** From the XML docs on `CheckInSession.Attendees` (`Rock/CheckIn/v2/CheckInSession.cs:~55-66`):

> "This property does not persist between API calls since a new session object is created each time. So the list of attendees would not be available when, for example, saving attendance."

Each request carries `ConfigurationTemplateId`, `KioskId`, `AreaIds` and the client's accumulated selections. The client owns the state. That is precisely the shape a hand-written HTML front-end wants.

DTOs are unremarkable POCOs, e.g.:

```csharp
public class AttendanceRequestBag   { string PersonId; OpportunitySelectionBag Selection; string Note; }
public class OpportunitySelectionBag{ CheckInItemBag AbilityLevel, Area, Group, Location, Schedule; }
public class SaveAttendanceResponseBag : CheckInResultBag { List<ClientLabelBag> Labels; }
```

Search modes available over REST — `Rock.Enums/CheckIn/FamilySearchMode.cs`: `PhoneNumber = 0, Name = 1, NameAndPhone = 2, ScannedId = 3, FamilyId = 4`. Barcode/RFID and direct family lookup are both on the table.

**Zero `[RockInternal]` on the contract.** Verified by grep: `Rock.ViewModels/Rest/CheckIn/` (18 files), `Rock.ViewModels/CheckIn/` (33 files), and `Rock.ViewModels/CheckIn/Labels/` (14 files) contain **no** occurrence of `RockInternal`. Per this repo's own CLAUDE.md conventions, that is the marker Rock uses for "experimental, may change" — its absence across the entire DTO surface is meaningful.

### 2.3 What the API does *not* cover — read this before scoping

The REST controller covers the check-in *flow*. A material amount of kiosk functionality exists **only** as Obsidian block actions on `Rock.Blocks/CheckIn/CheckInKiosk.cs`, reachable at `api/v2/blockactions/{pageGuid}/{blockGuid}/{actionName}` (`Rock.Rest/v2/BlockActionsController.cs:63, 103, 121`):

| Capability | Block action (line) |
|---|---|
| Kiosk configuration for the block | `GetKioskConfiguration` (`:979`) |
| Promotions / attract loop | `GetPromotionList` (`:999`) |
| Pre-check-in label printing | `PrintPreCheckInLabels` (`:1027`) |
| Real-time subscription (live counts) | `SubscribeToRealTime` (`:1074`) |
| Remove an attendee | `RemoveAttendee` (`:1144`) |
| Current attendance | `GetCurrentAttendance` (`:1197`) |
| Supervisor PIN validation | `ValidatePinCode` (`:1244`) |
| Open/close a room | `SetLocationStatus` (`:1264`) |
| Label reprint | `GetReprintAttendanceList` (`:1300`), `PrintLabels` (`:1328`) |
| Scheduled locations | `GetScheduledLocations` (`:1381`), `SaveScheduledLocations` (`:1494`) |
| **Family registration / edit** | `EditFamily` (`:1586`), `BeginAddIndividual` (`:1600`), `SaveFamily` (`:1611`), `AddIndividual` (`:1659`) |

Confirmed absent from REST: grep for `LocationStatus|locationCount|IsLocationCountDisplayed` in `Rock.Rest/v2/CheckInController.cs` returns nothing.

Consequence: **first-time family registration is not on the check-in REST API.** `FamilyRegistration` is used only from `Rock.Blocks/CheckIn/CheckInKiosk.cs:883, 1637, 1680` and `Rock.Blocks/Mobile/CheckIn/CheckIn.cs:772`. A custom front-end must either call block actions (a less stable contract — see §5.4), send new families elsewhere, or use Lava entity writes for person creation.

### 2.4 Auth and the kiosk identity story

Two attributes, two different jobs:

- **`[Authenticate]`** (`Rock.Rest/Filters/AuthenticateAttribute.cs`) **never rejects anything.** It only resolves a principal, from: an existing thread principal / Rock login cookie; OIDC bearer token; the **`Authorization-Token` header or `?apikey=` query string** matched against `UserLogin.ApiKey`; or a JWT.
- **`[Secured(...)]`** (`Rock.Rest/Filters/SecuredAttribute.cs`) does the rejecting. It resolves the `ISecured` item via `RestActionCache` → `RestControllerCache` → `new RestController()`, then evaluates `item.IsAuthorized( action, person )` where `person` **may be null**, and returns `401` on failure. It also honours `rckipid=` impersonation tokens and explicitly rejects PIN-authenticated logins with 401.

Anonymous therefore works only if an administrator grants it, via `Rock/Security/Authorization.cs:1242-1262`:

```csharp
if ( authRule.SpecialRole == SpecialRole.AllUsers ) { matchFound = true; authorized = authRule.AllowOrDeny == 'A'; break; }
if ( authRule.SpecialRole == SpecialRole.AllAuthenticatedUsers   && personGuid.HasValue )  { ... }
if ( authRule.SpecialRole == SpecialRole.AllUnAuthenticatedUsers && !personGuid.HasValue ) { ... }
```

Nothing is seeded by default: the migration that created the check-in REST controller — `Rock.Migrations/Migrations/Version 16.0/Version 1.16.6/202406281837177_CreateCheckInLabelModel.cs:101` — calls `RockMigrationHelper.AddRestController( "CheckIn", "Rock.Rest.v2.CheckInController" )` and adds auth only for the `Rock.Model.CheckInLabel` entity type (`:66-82`). **No anonymous rule is created on the check-in REST actions.**

**Rock's own documented answer is the REST-key pattern, and it is stated in the product itself.** `Rock.Blocks/CheckIn/CheckInKiosk.cs:131-137`:

> `[CustomDropdownListField( "REST Key", Description = "If your kiosk pages are configured for anonymous access then you must create a REST key with access to the check-in API endpoints and select it here.", ... )]`

The list source (`:115-119`) selects `UserLogin` rows whose person `RecordTypeValueId` is `PERSON_RECORD_TYPE_RESTUSER`. `GetObsidianBlockInitialization()` (`:126-160`) resolves that login's `ApiKey` and ships it to the browser; if no REST key is configured and nobody is logged in, it redirects to the login page instead. The client then appends it to every call — `checkInSession.partial.ts:283-289`:

```ts
private getApiUrl(baseUrl: string): string {
    if (this.apiKey) { return `${baseUrl}?apiKey=${this.apiKey}`; }
    return baseUrl;
}
```

and `welcomeScreen.partial.obs:321-324` does the same for `KioskStatus`.

**So a custom front-end must present exactly this.** Concretely: create a Person with record type *REST User*, give it a `UserLogin` with an API key, grant that login **Execute Read** and **Execute Write** on the check-in REST actions, and pass `?apiKey=…` on every request.

**Security note to carry into the spec:** in Rock's own kiosk the API key is delivered to the browser and is visible in page source and the network tab. That is Rock's accepted posture for kiosks, not an oversight — but it is a real exposure, and it is a genuine (if modest) point in Helix's favour: a Lava Endpoint calling `{% webrequest %}` server-side keeps the key on the server.

**[SECONDARY]** There is no official documentation of a Next Gen kiosk *user*-authentication model. The published check-in book documents *device* identification (matching a Device record by IP address, optionally by hostname) but never explains kiosk login, anonymous access, or API keys. The only documented kiosk-login approach found anywhere is a ~7-year-old community recipe using a long-lived `rckipid` person token — pre-Next-Gen and explicitly not endorsed by the core team. **The REST-key pattern quoted above, straight from the block's own attribute text, is a better-grounded answer than anything published.**

### 2.5 Two endpoints that are not like the others

- **`CloudPrint/{deviceId}` is genuinely unauthenticated.** No `[Authenticate]`, no `[Secured]`, only `[ExcludeSecurityActions(...)]` — and `ApiControllerBase` has no class-level `[Secured]` either (`Rock.Rest/ApiControllerBase.cs:54-55`, only `[ODataRouting]`). Anyone who can reach the URL and knows a device id can register as that printer proxy. **[SECONDARY]** Rock's Swagger publishes it with the summary "Establishes a connection from the printer proxy service to this Rock instance." Worth a security conversation independent of this ticket.
- **`ProximityCheckIn` has `[Authenticate]` but no `[Secured]`**, and hand-rolls its own check: `Unauthorized()` when `RockRequestContext.CurrentPerson == null`. It requires a real logged-in person, so an API key belonging to a REST user works but an anonymous kiosk does not.

Note that `[ExcludeSecurityActions]` is a marker only — `Rock/Security/ExcludeSecurityActionsAttribute.cs` just carries `string[] Actions` and controls which actions are *offered* for configuration on the REST action. It does not grant or deny anything at runtime.

### 2.6 The narrow sense in which the door really is shut

Every meaningful type in the engine is C# `internal`:

| Type | Declaration |
|---|---|
| `Rock/CheckIn/v2/CheckInDirector.cs:42` | `internal class CheckInDirector` |
| `Rock/CheckIn/v2/CheckInSession.cs:36` | `internal class CheckInSession` |
| `Rock/CheckIn/v2/CheckInManager.cs:35` | `internal class CheckInManager` |
| `Rock/CheckIn/v2/FamilyRegistration.cs:36` | `internal class FamilyRegistration` |
| `Rock/CheckIn/v2/ProximityDirector.cs:36` | `internal class ProximityDirector` |
| `DefaultSearchProvider.cs:34`, `DefaultSelectionProvider.cs:33`, `DefaultSaveProvider.cs:38`, `DefaultLabelProvider.cs:44`, `DefaultConversionProvider`, `DefaultOpportunityFilterProvider` | all `internal class` |
| `TemplateConfigurationData`, `OpportunityCollection`, `Attendee`, `AreaOpportunity`, `AbilityLevelOpportunity`, `AttendanceSessionRequest`, `AreaConfigurationData`, `CheckInFieldFilterBuilder`, `CloudPrintSocket`, all `Labels/*` | all `internal` |

The single exception in the whole namespace is `Rock/CheckIn/v2/FamilyRegistrationSaveResult.cs` — `public class`, a behaviourless result DTO.

And the gate list — `Rock/Properties/AssemblyInfo.cs:19-35` — is core-only:

```
Rock.AI.Agent, Rock.AI.Agent.Tests, Rock.Blocks, Rock.CodeGeneration, Rock.Migrations,
Rock.Oidc, Rock.RealTime.Dynamic, Rock.Rest, Rock.Tests(.Shared/.Integration/…),
Rock.Update, Rock.WebStartup, Rock.AI.OpenAI, DynamicProxyGenAssembly2
```

You cannot add an assembly to that list without recompiling Rock. **This is real and it is intentional** — Rock's own WebForms code has to pick the lock, complete with a confession, at `RockWeb/Blocks/CheckIn/Config/CheckinTypeDetail.ascx.cs:436-440`:

```csharp
// I know, this is a terrible hack. But we need to force the
// kiosks to refresh and we don't want to make this public yet. -dsh
typeof( GroupType ).Assembly.GetType( "Rock.CheckIn.v2.CheckInDirector" )
    .GetMethod( "SendRefreshKioskConfiguration" )
    .Invoke( null, new object[0] );
```

The only sanctioned public bridges into v2 are two methods on `Rock/Utility/ZebraPrint.cs`, both marked `[RockInternal( "1.16.7", true )]` (`:215`, `:245`) — i.e. permanently internal, public only because RockWeb needs it.

**Full consumer list for `CheckInDirector`** (exhaustive; `CheckInSession` is constructed only at `CheckInDirector.cs:350-352` and in tests):

- REST: `Rock.Rest/v2/CheckInController.cs`
- Obsidian blocks: `Rock.Blocks/CheckIn/CheckInKiosk.cs`, `CheckInKioskSetup.cs`, `Configuration/CheckInLabelDetail.cs:573`, `Configuration/CheckInSimulator.cs:69`, `Configuration/LabelDesigner.cs:490`, `Manager/Roster.cs`
- Mobile: `Rock.Blocks/Mobile/CheckIn/CheckIn.cs`
- Workflow action: `Rock/Workflow/Action/CheckIn/PrintLabels.cs:94`
- SaveHooks (cache invalidation only, `SendRefreshKioskConfiguration()`): `Campus`, `Device`, `Location`, `Schedule`, `ScheduleCategoryExclusion`, `GroupLocation`, `GroupType`
- Legacy bridge: `Rock/Utility/ZebraPrint.cs:218, 248`; reflection hack above
- **Jobs: none. Lava: none.**

**How to state this accurately:** *"You can't call the check-in engine in-process from a plugin or from Lava — those classes are `internal`. But the entire engine is exposed over HTTP at `api/v2/checkin/*`, and that is the only way Rock's own kiosk talks to it."*

---

## 3. Q2 — What Helix / Lava Applications can actually do

### 3.1 What Helix is

**Helix is htmx 2.0.0 plus a ~200-line Rock wrapper.** Not a metaphor — `RockWeb/Scripts/Rock/helix-script.js` opens with:

```js
/**
 * HTMX Script (2.0.0)
 */
var htmx = function () { ... version: "2.0.0" ...
```

The bundle is htmx verbatim (`hx-boost`, `hx-swap`, `hx-target`, `hx-trigger`, `hx-vals`, `hx-push-url`, `hx-swap-oob`, `hx:poll:trigger` all present). The string "Helix" does not appear inside the htmx portion at all. After it comes Rock's own IIFE which hooks `htmx:configRequest` to inject the CSRF header and do Lava form validation:

```js
evt.detail.headers["X-Helix-CSRF-Protection"] = true;
```

**Provenance:** Helix was a Triumph Tech plugin absorbed into Rock core in v18.0. `Rock/Utility/Reflection.cs:~1045-1057` still carries the assembly-scan exclusion with the note:

```csharp
// This was moved into core in v18.0, it can be removed in v19.0
"tech.triumph.Lava.Helix.dll"
```

and stale `.obs.js.map` artifacts remain under `RockWeb/Plugins/tech_triumph/LavaHelix/`. The migration is `Rock.Migrations/Migrations/Version 18.0/Version 18.0/202505072235453_AddLavaApplications.cs`.

**[SECONDARY]** Rock's release notes date it to **v18.1, 8 Dec 2025**: "Added Helix support for Lava Applications to core. This provides a great new way to build interactive pages in Rock powered by Lava for more advanced administrators." Jon Edmiston confirmed on the Triumph repo (2026-01-06) that "The Helix plugin has been moved to Rock Core." **Docs-currency hazard:** the Helix landing and install pages *still* say "early alpha… be prepared for changes, some of which may disrupt your initial projects" and "Currently in Limited Beta… being tested by a few select organizations," and still tell you to install it from Rock Shop. Those pages are stale relative to the release note and to this codebase. Treat the alpha language as out of date — but note that it is the kind of thing that will be quoted at you.

**[SECONDARY]** Triumph's own statement of intent, from the archived Helix docs: *"…enabling them to achieve more without needing extensive expertise in C# and Obsidian development."* Rock positions it as *"enhanced capabilities without necessitating a move to the highest level of customization."* That is a fair description of what it is for — and it is not "a fast kiosk runtime."

### 3.2 Execution model

Two halves.

**Lava Application Content block** — `Rock.Blocks/Cms/LavaApplicationContent.cs`. Settings: `Application` (dropdown from `SELECT [Guid],[Name] FROM [LavaApplication]`), `LavaTemplate` (code editor), and `[LavaCommandsField( "Enabled Lava Commands" )]`. It injects the runtime and renders:

```csharp
protected override string GetInitialHtmlContent()
{
    RequestContext.Response.AddScriptLinkToHead( "/Scripts/Rock/helix-script.js", true );
    RequestContext.Response.AddCssLink( "/Styles/Blocks/Cms/helix.css", true );
    return GetContent();
}
```

with `LavaApplication` and `ConfigurationRigging` added to the merge fields (`:79-80`, `GetContent()`).

**Lava Endpoints** — server-side HTTP handlers. `Rock.Rest/v2/LavaAppController.cs`, `[RoutePrefix( "api/v2/lava-app" )]`, four routes all shaped `1/{applicationSlug}/{*endpointSlug}` for GET / HEAD / POST / PUT, each `[Authenticate]` + `[ExcludeSecurityActions(all four)]`. Pipeline: `GetApplicationEndpoint` → `CheckCrossSiteForgery` → `IsAuthorized` → `SetupObservability` → `MergeRequest`.

Model: `Rock/Model/CMS/LavaEndpoint/LavaEndpoint.cs` — `Name, Description, LavaApplicationId, Slug, SecurityMode, IsActive, HttpMethod, CodeTemplate, EnabledLavaCommands (:157), CacheControlHeaderSettings, RateLimitPeriodDurationSeconds, RateLimitRequestPerPeriod`. `SupportedActions` includes **EXECUTE** — "access to execute the endpoint when the application is set to custom authentication." Security modes (`Rock.Enums/Cms/LavaEndpointSecurityMode.cs`): `EndpointExecute = 0, ApplicationView = 1, ApplicationEdit = 2, ApplicationAdministrate = 3`. Authorization is `context.LavaEndpoint.IsAuthorized( "Execute", context.CurrentPerson )`.

The endpoint body receives the whole request as merge fields — `Rock/Cms/LavaApplicationRequestHelpers.cs:45-101`: `RawUrl, Method, QueryString, RemoteAddress, RemoteName, ServerName, Form, Headers` (Authorization and Cookie stripped), `Cookies`, and for non-GET `RawBody` plus a parsed `Body` when the content type is JSON.

**Three things to know about the endpoint contract:**

1. **Responses are always HTML.** `ProcessEndpoint` returns `new StringContent( context.EndpointResponse.Content, Encoding.UTF8, "text/html" )`. Lava Endpoints are a hypermedia surface, not a JSON API.
2. **CSRF is a header-presence check, not a token.** `CheckCrossSiteForgery` only verifies that `X-Helix-CSRF-Protection` is present and truthy. It stops naive cross-origin form posts; it is not a real CSRF token scheme.
3. **Lava errors are swallowed.** `MergeRequest` wraps `CodeTemplate.ResolveMergeFields(...)` in `try { } catch ( Exception ) { }` with an empty handler. A template that throws yields a blank fragment and no signal. Plan your own error surfacing.

### 3.3 Can Lava invoke the check-in engine? No in-process; yes over HTTP

Exhaustive sweep of Lava's surface:

- **Shortcodes.** Eight code-based (`aicompletion, bootstrapalert, groupfinder, mediaplayer, networkgraph, sankeydiagram, scheduledcontent, scripturize`) in `Rock/Lava/Shortcodes/`, registered by reflection over `ILavaShortcode` (`Rock/Lava/LavaEngineFactory.cs:108-123`), plus DB-defined ones from the `LavaShortcode` table (`:137-144`). **Zero hits for `checkin|check-in|attendance|kiosk` across `Rock/Lava/Shortcodes/` and the entire `Rock.Lava/` project. No check-in shortcode exists.**
- **Commands/blocks.** 15 secured commands in `Rock/Lava/Blocks/`. None reaches the check-in engine. The one that so much as `using`s the namespace is `PrintZplBlock.cs:25` (`using Rock.CheckIn.v2.Labels;`) and it touches only `LabelPrintProvider` and `RenderedLabel` — printer transport, never attendance or check-in state.
- **Filters.** Only read-only attendance history on `Person`: `GroupsAttended` (`Rock/Lava/Filters/LavaFilters.Person.cs:1028`), `LastAttendedGroupOfType` (`:1055`), and a legacy unwrap of `CheckIn.CheckInPerson` → `Person` (`:1352-1355`).
- **`{% execute %}`** — `Rock/Lava/Blocks/ExecuteBlock.cs:30` compiles arbitrary C# at runtime: `CSScript.Evaluator.LoadCode<ILavaScript>( script )` (`:120`), auto-importing `System, Rock, Rock.Model, Rock.Data`, with arbitrary extra namespaces via `import:`. Full trust, no sandbox, gated only by the `Execute` enabled-command flag. **But it compiles into a separate dynamic assembly, which is not on `InternalsVisibleTo`, so it cannot bind to `CheckInDirector` by name.** Only hand-written non-public reflection could — the same lock-picking as §2.6, and just as unsupportable.
- **`{% <entity> %}`** — `RockEntityBlock` reflects on exactly one method (`:256`): `Service<T>.Get( ParameterExpression, Expression, SortProperty, int? )`. There is no "call any service method" facility. `{% attendance %}` reads Attendance rows; it cannot invoke `AttendanceService` business methods.
- **`{% webrequest %}`** — `Rock/Lava/Blocks/WebRequestBlock.cs:36`, RestSharp-backed: `new RestClient( parms["url"] )` (`:72`), method (`:74`), basic auth (`:81-88`), query params (`:91-97`), arbitrary headers (`:100-106`), request body with `requestcontenttype` (`:109-116`). **This is the supported route: a Lava Endpoint can `POST` to `api/v2/checkin/*` server-side, over loopback, with the API key never leaving the server.**

One thing worth flagging about command gating generally — `Rock.Lava/Core/LavaSecurityHelper.cs:35-54` is a pure string-list membership test with **no user or role check**:

```csharp
var enabledCommands = context.GetEnabledCommands();
if ( enabledCommands.Any() ) {
    if ( enabledCommands.Contains( "All", StringComparer.OrdinalIgnoreCase )
         || enabledCommands.Contains( command, StringComparer.OrdinalIgnoreCase ) ) { return true; }
}
return false;
```

Whoever can edit the Lava has whatever the enabled-commands list allows. Lava Endpoints at least scope this per endpoint (`LavaAppController.cs:293-297` uses `context.LavaEndpoint.EnabledLavaCommands`), which is better than the global default — see §4.2 for where that goes wrong on labels.

### 3.4 The trap: writing attendance from Lava

Lava **can** write attendance rows, and it must not. `RockEntityModifyBlock` registers `modify<entity>` for every entity type (`Rock/Lava/Blocks/RockEntityModifyBlock.cs:934, 979`) and `RockEntityDeleteBlock` registers `delete<entity>` (`:813`). So `{% modifyattendance %}` and `{% sql %}` are both live paths to the `Attendance` table.

Doing so bypasses **everything** the check-in engine exists to do: opportunity filters, capacity and threshold checks, ability-level and grade logic, duplicate suppression, security-code generation, achievements, and label generation. It also has a known bug — `ModifiedByPersonAliasId` is not set (open issue on the Triumph repo) **[SECONDARY]**.

Record this as an explicit anti-pattern in the spec. It is the most likely way a Helix-based check-in quietly goes wrong.

### 3.5 What Helix genuinely brings

- **A form-control toolkit.** The v18 migration seeds 12 Lava shortcodes, all UI controls: `campuspicker, checkboxlist, currency, datepicker, daterangepicker, definedvaluepicker, dropdown, memo, radiobuttonlist, rangeslider, rockcontrol, textbox` (`202505072235453_AddLavaApplications.cs:746-757` and `:915-1564`).
- **Unrestricted access to Rock data.** This is the real answer to the ticket's "keeping desired fields." The check-in API's DTOs are closed shapes:
  - `Rock.ViewModels/CheckIn/PersonBag.cs` carries `Id, FirstName, NickName, LastName, FullName, BirthYear/Month/Day, BirthDate, Gender, Age, AgePrecise, GradeOffset, GradeFormatted, AbilityLevel, IsSpecialNeeds, PhotoUrl` — **and no person attributes.**
  - `Rock.ViewModels/CheckIn/ConfigurationTemplateBag.cs` carries behaviour flags only (`AbilityLevelDetermination, FamilySearchType, IsAutoSelect, IsCheckoutAtKioskAllowed, IsPhotoHidden, IsSupervisorEnabled, Min/MaximumPhoneNumberLength`, …) — **and no Lava templates.**

  If you need an allergy attribute, a custom flag, a campus-specific message, or anything else next to a check-in screen, the REST API will not give it to you. A Lava Endpoint will. **That is Helix's strongest argument in this ticket.**
- **Server-side ZPL printing** without a native wrapper — see §4.6.
- **Built-in observability** — endpoints emit activities named `LavaEndpoint: {Name} | {Application}` **[SECONDARY]**.
- **Per-endpoint rate limiting and cache headers**, on the model (`LavaEndpoint.cs`).

### 3.6 Friction to plan around

- **htmx wants HTML; the check-in API returns JSON.** htmx cannot drive `api/v2/checkin/*` directly. Either wrap each call in a Lava Endpoint (`{% webrequest %}` → parse JSON → render a fragment), or use plain `fetch()` inside the Lava Application page. The second is simpler and faster; it also means htmx is doing less than you might expect, which is worth being honest about when choosing Helix "for" htmx.
- **`{% javascript %}` and `{% stylesheet %}` do not work in Helix.** **[SECONDARY]** Rock's docs state they "rely on RockPage to execute and render their markup. Since Helix dynamically updates portions of the page, RockPage isn't available." Confirmed in code that `JavascriptBlock` and `StylesheetBlock` exist as ungated blocks — but the docs' explanation of why they misbehave under fragment swapping is credible and matches the architecture.
- **No file/binary upload into a Lava Endpoint.** **[SECONDARY]** Open issue since 2024-09: uploads are absent from the `Form` merge field and reachable only as an unparseable `RawBody` string. The reporter's own example was **camera capture** — so if photo capture at the kiosk is ever in scope, it cannot go through a Lava Endpoint.
- **"Everything is assumed to be web."** **[SECONDARY]** Open issue filed by Jon Edmiston: an endpoint cannot tell what platform is calling it.
- **Soft ceiling around 50 endpoints.** **[SECONDARY]** Rock's own "signs you've outgrown Lava Applications" list: "Your application requires 50+ endpoints" / "The development of your application feels overly complex and fragile."
- **Security is explicitly the author's problem.** **[SECONDARY]** Rock's Helix security page: "your endpoints might be accessed externally, not just through your frontend"; users can "intercept these calls and replicate them using tools like curl or Postman, modifying parameters"; SQL-injection sanitization is on you.
- **No offline story.** **[SECONDARY]** Absent from the Helix docs and from the published roadmap. The roadmap also never mentions check-in or kiosks.

**[SECONDARY] Explicit negative, checked in both directions:** no official documentation anywhere mentions using Lava Applications or Helix for check-in, and the Next Gen check-in book contains zero occurrences of "Lava Applications" or "Helix." No forum thread or GitHub issue discusses either building a custom check-in front-end on `api/v2/checkin` or using Helix for check-in. This would be new ground. (Rock's live discussion has largely moved to RocketChat, which is not web-indexed — there is a `#check-in` channel that is the most likely place such a conversation exists, and it was not reachable for this research.)

---

## 4. Q3 — Printing

### 4.1 How labels are produced

Labels are **ZPL**, rendered server-side by `Rock/CheckIn/v2/DefaultLabelProvider.cs` (`internal class`, `:44`), in two formats — `RenderLabel` (`:561-620`):

```csharp
if ( label.LabelFormat == LabelFormat.Zpl )
{
    var mergeFields = new Dictionary<string, object>();
    foreach ( var prop in labelData.GetType().GetProperties() ) { mergeFields.Add( prop.Name, prop.GetValue( labelData ) ); }
    var zpl = label.Content.ResolveMergeFields( mergeFields );   // Lava → ZPL
    return new RenderedLabel { ..., Data = Encoding.UTF8.GetBytes( zpl ), PrintTo = printer };
}
// else: designed label — DesignedLabelBag JSON → ZplLabelRenderer
var designedLabel = label.Content.FromJsonOrNull<DesignedLabelBag>();
var hasCutter = printer?.GetAttributeValue( DeviceAttributeKey.DEVICE_HAS_CUTTER ).AsBoolean() ?? false;
var dpi = printer?.GetAttributeValue( DeviceAttributeKey.DEVICE_PRINTER_DPI ).AsIntegerOrNull();
var renderer = new ZplLabelRenderer();
```

ZPL confirmed at the byte level in `Rock/CheckIn/v2/Labels/LabelPrintProvider.cs` (cut and backfeed sequences `^MMC^XZ\r\n`, `^XB^XZ\r\n`).

**Lava survives inside labels on both paths — this matters for the ticket's "keeping Lava customization."** Three call sites:

1. Raw-ZPL label bodies: `DefaultLabelProvider.cs:566-574` merges the entire `CheckInLabel.Content`.
2. Designed-label dynamic text: `Rock/CheckIn/v2/Labels/LabelField.cs:99-104` — `config.DynamicTextTemplate.ResolveMergeFields( mergeFields )`.
3. Designed-label dynamic barcodes: `Rock/CheckIn/v2/Labels/Renderers/ZplLabelRenderer.cs:513-516`.

The Lava data model is built by reflection over the label-data object — `Rock/CheckIn/v2/Labels/PrintLabelRequest.cs:72-92` — and wrapped by `LavaDataWrapper` (`Rock.Lava.Shared/Core/LavaDataWrapper.cs:25, 42`), which is why the `internal` label-data classes (`AttendanceLabelData`, `PersonLabelData`, `FamilyLabelData`, `CheckoutLabelData`) are still readable from Lava.

**Whatever front-end you build, label templates remain fully Lava-customizable and fully server-rendered.** No custom-UI decision touches this.

### 4.2 Security note on label Lava

Those three sites call the `ResolveMergeFields( mergeObjects )` overload, which pulls enabled commands from a **global** setting — `Rock/Utility/ExtensionMethods/LavaExtensions.cs:540-544`:

```csharp
var enabledCommands = GlobalAttributesCache.Get().GetValue( "DefaultEnabledLavaCommands" );
return content.ResolveMergeFields( mergeObjects, enabledCommands, encodeStrings, throwExceptionOnErrors );
```

So if `DefaultEnabledLavaCommands` includes `Execute`, `Sql`, or `WebRequest`, a **check-in label template becomes a place those commands run**, on the print path. Worth checking this fork's global setting as a side finding. (Contrast: Lava Endpoints pass an explicit per-endpoint list.)

### 4.3 Where printing happens — decided entirely by Device records

`DefaultLabelProvider.cs:684`:

```csharp
labelData.PrintFrom = kiosk?.PrintFrom ?? PrintFrom.Server;
```

`GetPrintToDevice` (`:699-728`):

```csharp
var printTo = kiosk?.PrintToOverride ?? PrintTo.Default;
if ( printTo == PrintTo.Default ) { printTo = attendance.Area.AttendancePrintTo; }
if ( printTo == PrintTo.Kiosk && kiosk != null && kiosk.PrinterDeviceId.HasValue ) { return DeviceCache.Get( kiosk.PrinterDeviceId.Value, RockContext ); }
else if ( printTo == PrintTo.Location && attendance.Location.PrinterDeviceId.HasValue ) { return DeviceCache.Get( attendance.Location.PrinterDeviceId.Value, RockContext ); }
return null;
```

Enums: `Rock.Enums/Core/PrintFrom.cs` — `Client = 0, Server = 1`; `Rock.Enums/Core/PrintTo.cs` — `Default = 0, Kiosk = 1, Location = 2`. Device fields: `Rock/Model/Core/Device/Device.cs` — `IPAddress` (`:98`), `PrinterDeviceId` (`:108`), `ProxyDeviceId` (`:118`, "Currently this means a printer proxy"), `PrintFrom` (`:128`), `PrintToOverride` (`:139`).

Then the split, `PrintLabelsAsync` (`:144-182`):

```csharp
var labelsToPrint = labels.Where( l => l.Error.IsNullOrWhiteSpace() && l.Data != null && l.PrintFrom == PrintFrom.Server );
var printErrorMessages = await printProvider.PrintLabelsAsync( labelsToPrint, cancellationToken );
...
return labels.Where( l => l.Error.IsNullOrWhiteSpace() && l.Data != null && l.PrintFrom == PrintFrom.Client ).ToList();
```

**Server labels are printed inside the API call. Client labels are handed back to the caller**, base64-encoded, from `PostSaveAttendance`:

```csharp
clientLabelBags = clientLabels
    .Where( l => l.Data != null && l.Error.IsNullOrWhiteSpace() )
    .Select( l => new ClientLabelBag { PrinterAddress = l.PrintTo?.IPAddress, Data = Convert.ToBase64String( l.Data ) } )
    .ToList();
```

So the answer to "does the REST API hand back label data, print server-side, or both" is **both — and which one you get is decided by the kiosk Device record, not by your client.**

### 4.4 Server-print transport: Cloud Print or raw TCP 9100

`LabelPrintProvider.PrintDeviceLabelsAsync`:

```csharp
if ( printerDevice.ProxyDeviceId.HasValue )
{
    var proxy = CloudPrintSocket.GetBestProxyForDevice( printerDevice.ProxyDeviceId.Value );
    if ( proxy != null ) { var message = await proxy.PrintAsync( printerDevice, labelContents, cancellationToken ); }
    else { var response = await CloudPrintLabelMessage.RequestAsync( printerDevice.ProxyDeviceId.Value, printerDevice.Id, labelContents, cancellationToken ); }
}
else { var directMessages = await PrintToIpEndpointAsync( printerDevice.IPAddress, labelContents, cancellationToken ); }
```

`OpenSocketAsync` sets `int printerPort = 9100;` with `ip:port` override, then writes to a raw `Socket`/`NetworkStream`.

- **With `ProxyDeviceId`:** routed to a Cloud Print proxy. `Rock/CheckIn/v2/CloudPrintSocket.cs` (`internal sealed class : ProxyWebSocket`) keeps a static registry `Dictionary<int, List<CloudPrintSocket>> _proxies` (`:49`) keyed by proxy device id, with `GetBestProxyForDevice` (`:249`), `GetAllProxiesForDevice` (`:270`), `PingProxyAsync` (`:386`). If this web node does not hold the socket, `Rock/CheckIn/v2/CloudPrintLabelConsumer.cs` (`[DynamicConsumer] internal class CloudPrintLabelConsumer : RockConsumer<CloudPrintCommandQueue, CloudPrintLabelMessage>`) routes the job across the farm over MassTransit.
- **Without it:** Rock opens a TCP connection straight to the printer's IP on port 9100. **Requires network reachability from the Rock server to the printer.**

The proxy itself is an on-prem app — `Applications/RockCloudPrint/` (`Rock.CloudPrint.Service` with `ProxyWorker`/`ProxyClientWebSocket`, `Rock.CloudPrint.Desktop` WPF, shared libs). It dials **out** to Rock — `ProxyWorker.cs:231`:

```csharp
uri = new Uri( uri, $"api/v2/checkin/cloudprint/{options.Id}?name={name}" );
```

with `https→wss` / `http→ws` rewriting. Outbound WSS from the church LAN; no inbound firewall holes.

**[SECONDARY]** Rock's documented Cloud Print prerequisites: **WebSockets must be enabled in IIS**; a Cloud Print Proxy Device record in Rock; the proxy service installed on an on-prem Windows machine ("any Windows check-in device you already have, or a small, dedicated computer like an Intel NUC"), configured with Server URL + Proxy Id + name; and **the kiosk configuration set to `Server` print mode**. Multiple proxies for redundancy at scale. Rock's documented alternatives — VPN tunnel ("complex setup, reliability issues, and potential security risks") and local-network printing ("difficult to scale") — are both worse for cloud-hosted Rock.

### 4.5 The hard constraint: a browser cannot print client-side

`Rock.JavaScript.Obsidian.Blocks/src/CheckIn/CheckInKiosk/utils.partial.ts:272-299`:

```ts
export async function printLabels(labels: ClientLabelBag[]): Promise<string[]> {
    if (labels.length === 0) { return []; }
    const native = window["RockCheckinNative"] as IRockCheckInNative | undefined;
    if (native?.PrintV2Labels) {
        try { return await native.PrintV2Labels(JSON.stringify(labels)); }
        catch (error) { /* … */ }
    }
    else { return ["Device does not support printing."]; }
}
```

`IRockCheckInNative` is declared in `.../CheckInKiosk/types.partial.ts:255`, documented as "The interface that the native application provides when the web page is running in the iOS or Windows native app," exposing `PrintLabels?(tagJson)` (v1) and `PrintV2Labels?(tagJson)` (v2). `printLegacyLabels` has the same requirement.

**There is no browser API for raw TCP to a printer. Client-side printing requires the native iOS or Windows check-in wrapper app. Full stop.**

**[SECONDARY]** Rock's own documentation says this in plain language, which is useful for the ticket write-up:

> "To be able to print from the client you must use either the iPad or Windows applications."
>
> "**Client:** This is the best option, but it assumes that you will be using the iPad application or Windows application. **If you are running check-in inside a web browser, you won't be able to print from the client.**"
>
> "The recommended approach to printing is to always print from the client using the printer defined on the client."

Corroborated by the iPad app listing: "This allows you to print to printers on your local network that are not connected to the Internet."

Note the sting: Rock's **recommended** print path is the one a browser-based front-end cannot use. Both ticket options are browser-based, so both give it up.

### 4.6 Answering the ticket's question directly

> *"Can printing be pushed to printers via Helix — possibly requiring printers configured on the 'devices' side of check-in so Helix can target the device?"*

**The instinct is correct, and it is necessary. It is not sufficient by itself.** Here is the full set of conditions for a browser-based front-end — custom HTML or Helix, identically:

1. **Printers must exist as `Device` records in Rock.** Non-negotiable: `GetPrintToDevice` resolves `DeviceCache` entries via `kiosk.PrinterDeviceId` / `location.PrinterDeviceId`. No Device record, no printer, `return null`.
2. **The kiosk must also be a `Device` record**, and its id passed as `KioskId` on every call — `PrintFrom`, `PrintToOverride` and `PrinterDeviceId` are all read off it.
3. **`Device.PrintFrom` must be `Server`** (`PrintFrom.Server = 1`). If it is `Client`, labels come back in the response and then die, because there is no native bridge in a browser.
4. **Rock must be able to reach the printer.** Either direct TCP 9100 (impossible for this fork — Rock is cloud-hosted on GCP, printers are on church LANs) or a Cloud Print proxy. **For this fork, the Cloud Print proxy is effectively mandatory**, which means: proxy device records, the proxy service deployed and supervised on-prem per campus, and WebSockets enabled on the Rock side.
5. **`PrintTo` routing must be configured** — `PrintTo.Kiosk` with `kiosk.PrinterDeviceId`, or `PrintTo.Location` with per-location printers, or `Area.AttendancePrintTo` as the default.

With all five true, **printing works and your front-end does nothing at all** — the labels print inside the `SaveAttendance` call, server-side, before the HTTP response returns. Your client can ignore the `Labels` array entirely.

This resolves a gap in the published docs: they state that browser clients cannot do *client* printing, and separately that Cloud Print is driven by `Server` print mode, but never join the two. **Primary sources join them: yes, a browser-based kiosk can print, via `PrintFrom.Server` + Cloud Print, with no client involvement.**

**The one asymmetry in Helix's favour.** `{% printzpl %}` — `Rock/Lava/Blocks/PrintZplBlock.cs:51`, permission key `PrintZpl` (`:204`) — lets Lava print ZPL server-side:

```csharp
if ( !deviceIdValue.IsNullOrWhiteSpace() )
{
    var device = DeviceCache.Get( deviceIdValue, true );
    if ( device == null ) { return new List<string> { "Invalid deviceid." }; }
    var renderedLabels = BuildLabels( zpl, device );
    return await printProvider.PrintLabelsAsync( renderedLabels, cancellationToken );   // ← full LabelPrintProvider
}
else if ( !ipAddressValue.IsNullOrWhiteSpace() )
{
    var renderedLabels = BuildLabels( zpl, null );
    return await LabelPrintProvider.PrintToIpEndpointAsync( ipAddressValue, labelContents, cancellationToken );
}
```

`BuildLabels` sets `PrintFrom = PrintFrom.Server`.

**This resolves an open question the published documentation leaves unanswered:** `deviceid` goes through `LabelPrintProvider.PrintLabelsAsync`, so it **inherits Cloud Print proxy routing automatically**; `ipaddress` bypasses the proxy and hits the printer directly on port 9100. **For this fork, always use `deviceid`.**

**Provenance check — `{% printzpl %}` is upstream Rock core, not fork-local.** This matters because a fork-local Lava command would be a liability. Verified two ways: `git cat-file -e upstream/develop:Rock/Lava/Blocks/PrintZplBlock.cs` succeeds (upstream develop, 2026-08-14), and this fork's ledger `Documentation/Fork-Local-Changes.md` lists only three fork-local changes (the Tabler icon migration, the Form Builder header image, and workflow person-entry width) — none related. **[SECONDARY]** Rock's Lava docs document it at `community.rockrms.com/lava/commands/print-zpl`, shipped in Lava v19.1. (Its absence from the local `develop` branch is a red herring — that snapshot is dated 2026-05-06, and the block carries an engineering note dated 3/4/2026 signed "NA", initials that appear throughout upstream core files.)

---

## 5. Q4 — Pros and cons

### 5.1 Comparison

| Dimension | [1] REST API + plain HTML/JS | [2] Helix / Lava Application | Notes |
|---|---|---|---|
| **Uses the Next Gen engine** | Yes, directly | Yes, over HTTP via `{% webrequest %}` or `fetch()` | Not a differentiator. Both inherit the engine's performance. |
| **Perceived performance** | Best. One JSON round trip per step, client-rendered | Slightly worse. Server renders HTML per interaction; an extra hop if a Lava Endpoint proxies to the REST API | Lava adds template parsing + a loopback call. Probably imperceptible next to network latency, but it is strictly more work per interaction. |
| **UI/UX ceiling** | Unlimited — it is your HTML/JS | High but htmx-shaped. Fragment swapping; `{% javascript %}` / `{% stylesheet %}` don't work **[SECONDARY]** | For unusual interactions the API path is freer. |
| **Lava customization** | **None in the UI.** Next Gen's kiosk contains zero Lava (`grep -rni "lava"` over `Rock.JavaScript.Obsidian.Blocks/src/CheckIn/` hits only the admin Label Designer's "Edit Lava Template" modal) | **This is the whole point.** Templates are Lava; full entity access | Labels stay Lava-customizable either way (§4.1). |
| **Custom / desired fields** | Hard. `PersonBag` has no attributes; `ConfigurationTemplateBag` has no Lava templates | Easy. `{% person %}`, `{% group %}`, `{% sql %}` fetch anything and interleave it | **The ticket's "keeping desired fields" is the strongest argument for Helix.** |
| **Printing** | Server-print + Cloud Print required | Identical, **plus** `{% printzpl %}` for bespoke labels | See §4.6. Not a large differentiator, but it leans Helix. |
| **Offline / kiosk resilience** | You can build it — service worker, local queue, retry (Rock's own kiosk polls `Configuration` to detect recovery, `checkInKiosk.obs:460`) | Poor. Server-rendered fragments need the server for every interaction; no offline story in docs or roadmap **[SECONDARY]** | **Leans API.** Neither approaches the native wrapper apps. |
| **Auth** | REST key in the browser (Rock's own pattern) | Same, **or** key held server-side in a Lava Endpoint | Small security edge to Helix. |
| **Dev effort** | Moderate–high. Auth, state machine, error handling, retries, printing config all by hand | Lower to first screen; friction later (no file upload, ~50-endpoint ceiling, swallowed Lava errors) | Helix is faster to a demo; the API path is more predictable at scale. |
| **Skills needed** | JS/TS + REST; C# only if block actions are needed | Lava + HTML/CSS + htmx concepts; **no C#** — Helix's stated purpose **[SECONDARY]** | Decide from who will maintain it in two years. |
| **Upgrade / maintenance risk** | **Lowest available.** Public DTOs, no `[RockInternal]`, `RestActionGuid`-stable routes | Same API risk **plus** Helix's own maturity risk | See §5.4. |
| **Feature completeness** | Missing registration, supervisor, reprint, room open/close, promotions, live counts (§2.3) | Same gaps; Lava entity writes can cover *some* registration, at the cost of bypassing engine logic (§3.4) | Both need a scoping decision here. |

### 5.2 What leans toward the API path

- Rock's own kiosk is this. Every bug you hit, Rock hits too.
- The contract is public and unmarked. Zero `[RockInternal]` across 65 check-in view-model files.
- Each action has a stable `[SystemGuid.RestActionGuid]`, so permissions and routes survive upgrades by design.
- The engine is stateless per call, so a thin client is the intended architecture, not a workaround.
- Offline/degraded behaviour is achievable because the client owns the state.
- **[SECONDARY]** All 11 endpoints are published in Rock's officially linked Swagger for v19.3.4 with no deprecation or internal markings.

### 5.3 What leans toward Helix

- It is the only path that answers "keep Lava customization and desired fields," because the REST DTOs are closed shapes with no attribute surface.
- Non-C# staff can own it — Helix's stated design goal.
- The API key can stay server-side.
- `{% printzpl %}` gives a first-class server-print escape hatch with Cloud Print routing for free.
- Observability and per-endpoint rate limiting come free.
- Bryson's "known to be fast for progressing through a process" is a fair characterization of htmx for form-driven flows — that is exactly what htmx is good at, and check-in is a wizard.

### 5.4 Upgrade risk, ranked

1. **`api/v2/checkin/*` + `Rock.ViewModels` DTOs — lowest risk.** Public, unmarked, GUID-stable, and Rock's own kiosk depends on them, so breaking them breaks Rock.
2. **Lava Applications / Helix — low-to-moderate.** In core since v18.1, but with an open-issue backlog and documentation that still calls it alpha in places **[SECONDARY]**. Also note Rock's roadmap for Helix says nothing about check-in — you would be the use case that shaped nothing.
3. **Obsidian block actions (`api/v2/blockactions/...`) — moderate-to-high.** They exist to serve a specific `.obs` file that ships alongside them. There is no compatibility promise, and any Obsidian refactor can rename an action or reshape a bag. **Necessary for registration/supervisor/reprint — treat as the risky part of the plan, not the foundation.**
4. **Anything reflecting into `Rock.CheckIn.v2` internals — unacceptable.** No compatibility contract at all; Rock's own comment says the type is deliberately non-public "yet."
5. **Fork-local risk — none identified.** `{% printzpl %}` is upstream (§4.6), and the fork ledger contains nothing check-in-related.

### 5.5 One more v1-vs-v2 distinction worth carrying

Legacy v1 exposes check-in state to Lava directly — `Rock/CheckIn/CheckInPerson.cs:32` (`: ILavaDataDictionary, IHasAttributesWrapper`), and likewise `CheckInGroup`, `CheckInGroupType`, `CheckInLocation`, `CheckInSchedule`, `CheckInMessage`, `KioskDevice.cs:34`, plus `CheckInFamily`/`CheckinResult` as `RockDynamic`. Legacy merge-field names are in `Rock/CheckIn/CheckInBlock.cs:115-155`, and the legacy controller (`Rock.Rest/Controllers/CheckinController.cs`) has `GetConfigurationStatus` (`:48-51`) and `PrintSessionLabels` (`:84-87`).

**Next Gen exposes nothing to Lava.** Grep for `ILavaDataDictionary|LavaDataObject|RockDynamic|LavaHidden|LavaVisible|LavaType` across `Rock/CheckIn/v2/` returns **zero** results.

This is the trap the ticket needs to avoid: the Classic Lava customization points still exist in configuration and are still read by `Rock/CheckIn/v2/TemplateConfigurationData.cs` (`SuccessLavaTemplateDisplay` `:320`, `PersonSelectAdditionalInformationLavaTemplate` `:397`, `StartLavaTemplate` `:413`, `SuccessLavaTemplate` `:421`) and are still editable in the admin UI (`Rock.Blocks/CheckIn/Config/CheckinTypeDetail.cs:536-538, 676-683`) — but they **never reach `ConfigurationTemplateBag`**, so the Next Gen client never sees them. Several settings in `Rock/CheckIn/v2/README.md` (the "Classic Check-in Settings" section, ~lines 760-910) are annotated as classic-only or next-gen-only for exactly this reason.

**Anyone reasoning from "Classic check-in was very Lava-customizable" will overestimate what Next Gen gives them.** That is very likely part of what motivated this ticket.

---

## 6. Open questions — these need a human

1. **What is the actual requirement behind "leverage Next Gen performance while keeping Lava customization"?** If it is *specific fields on specific screens*, Helix is right and the scope is small. If it is *a full Classic-style Lava-templated kiosk*, the scope is much larger and someone should push back on the premise. **This is the question that most changes the answer, and only the requester can answer it.**
2. **Is first-time family registration in scope?** Not on the REST API (§2.3). If yes, someone must choose: call block actions (moderate upgrade risk), send registration elsewhere, or accept Lava entity writes with all the engine logic bypassed. **A scoping decision, not a technical unknown.**
3. **Cloud Print operational readiness.** How many campuses, how many printers, who owns the on-prem proxy machines, who gets paged when a proxy drops? WebSockets must be enabled on the Rock side. Unresolvable from code; needs the infrastructure owner.
4. **Is the REST key in browser page source acceptable?** It is Rock's own posture, but it is this fork's risk decision. If not, that argues for routing every call through Lava Endpoints.
5. **What is `DefaultEnabledLavaCommands` set to in this Rock instance?** A runtime global-attribute value, not in the repo. If it includes `Execute`, `Sql`, or `WebRequest`, label templates become a code-execution surface (§4.2). Worth checking regardless of this ticket.
6. **Should the unauthenticated `CloudPrint/{deviceId}` endpoint be restricted at the edge?** Anyone who can reach it and knows a device id can register as a printer proxy (§2.5). Separate security conversation.
7. **Do you actually need Helix, or do you need htmx?** If the goal is a fast form-driven flow, `fetch()` + a little JS gets there without a dependency on a feature whose own docs still say "alpha" in places. If the goal is Lava authorship by non-C# staff, Helix is the answer. Different answers, same-looking request.
8. **Undetermined — where the `LavaApplication` / `LavaEndpoint` tables are actually created.** The `CreateTable` calls in `202505072235453_AddLavaApplications.cs` (lines ~156-211) are **commented out**, presumably because a plugin-era migration created them first. Harmless for this analysis but confusing on a fresh install; check the migration's `.Designer.cs`/`.resx` or a plugin hotfix if it ever matters.
9. **Unknown — whether Rock will support `api/v2/checkin` as a third-party contract.** Extensively searched **[SECONDARY]**: the API landing page distinguishes only "v1 Classic/legacy" from "v2 Fast," with no public/internal or support/stability statement; the developer changelog for v13.0–v20.0.8 documents breaking changes but has no v2-API or check-in-API section; none of the 17 tech bulletins touches the check-in API. **No statement was found in either direction — do not read the absence as either a promise or a warning.** The practical mitigation is the one that already applies: Rock's own kiosk depends on these endpoints, so they will not move quietly. To get a real answer, ask in the Rock community `#check-in` RocketChat channel, which is where this conversation would live and which is not web-indexed.
10. **Unknown — when Cloud Print was introduced, and its full prerequisites.** **[SECONDARY]** Zero occurrences of "Cloud Print", "cloudprint", "print proxy", or even "proxy" across published release notes v16.1–v19.4 and all tech bulletins; it is documented only in the check-in book, with no minimum version and no OS/.NET requirements beyond "WebSockets must be enabled." (One search-engine summary claimed v19.2/June 2026; uncorroborated, discard it.) It is present and functional in this codebase, so this is a documentation gap rather than a blocker — but do not promise a version floor to anyone.
11. **Unknown — the Next Gen check-in theme customization ceiling.** **[SECONDARY]** The book asserts you can add a theme "with some basic knowledge of HTML/CSS and Less" but documents no hooks and never says whether Lava is available in a check-in theme. v19.4 added identifying CSS classes (`kiosk-4 campus-1 configuration-template-14`). **This is worth someone's hour before either custom-front-end option is chosen — a theme may satisfy part of the requirement at a fraction of the cost, and nobody has priced that option.**

---

## 7. Sources

### 7.1 Primary — code in this working copy (`passion-19.3.4`)

**REST surface**
- `Rock.Rest/v2/CheckInController.cs` — `:57` route prefix; endpoints at `:87-95, 130-138, 176-184, 235-243, 297-305, 361-369, 431-439, 496-504, 548-556, 579-585, 625-633`; director construction at `:97, 140, 213, 261, 323, 391, 461, 526, 560`; `CloudPrintSocket` at `:611`; `ProximityDirector` at `:659`
- `Rock.Rest/ApiControllerBase.cs:54-55`
- `Rock.Rest/v2/BlockActionsController.cs:63, 103, 121`
- `Rock.Rest/Controllers/CheckinController.cs:48-51, 84-87` (legacy v1)
- `Rock.Rest/v2/LavaAppController.cs` — `:56` `X-Helix-CSRF-Protection`; `:293-297` enabled commands; `CheckCrossSiteForgery`, `IsAuthorized`, `MergeRequest`, `ProcessEndpoint`

**Security**
- `Rock.Rest/Filters/AuthenticateAttribute.cs`, `Rock.Rest/Filters/SecuredAttribute.cs`
- `Rock/Security/Authorization.cs:199, 212, 218, 225, 232` (EXECUTE constants), `:1242-1262` (SpecialRole)
- `Rock/Security/ExcludeSecurityActionsAttribute.cs`
- `Rock/Properties/AssemblyInfo.cs:19-35`

**Engine**
- `Rock/CheckIn/v2/CheckInDirector.cs:42, 350-352`; `CheckInSession.cs:36, ~55-66`; `CheckInManager.cs:35`; `FamilyRegistration.cs:36`; `ProximityDirector.cs:36, 94-101`
- `Rock/CheckIn/v2/TemplateConfigurationData.cs:320, 397, 413, 421`
- `Rock/CheckIn/v2/FamilyRegistrationSaveResult.cs` (the only public class in the namespace)
- `Rock/CheckIn/v2/README.md` (~760-910, Classic Check-in Settings)
- `Rock/RealTime/Topics/ICheckIn.cs`

**Labels & printing**
- `Rock/CheckIn/v2/DefaultLabelProvider.cs:44, 81, 111, 144-182, 561-620, 566-574, 684, 699-728`
- `Rock/CheckIn/v2/Labels/LabelPrintProvider.cs:36`, `PrintDeviceLabelsAsync`, `OpenSocketAsync` (port 9100), `PrintToIpEndpointAsync`
- `Rock/CheckIn/v2/Labels/RenderedLabel.cs`, `LabelField.cs:99-104`, `Renderers/ZplLabelRenderer.cs:513-516`, `PrintLabelRequest.cs:72-92`
- `Rock/CheckIn/v2/CloudPrintSocket.cs:36, 49, 143, 163, 206, 249, 270, 356, 386`; `CloudPrintLabelConsumer.cs`
- `Rock.Enums/Core/PrintFrom.cs`, `Rock.Enums/Core/PrintTo.cs`, `Rock.Enums/CheckIn/FamilySearchMode.cs`
- `Rock/Model/Core/Device/Device.cs:98, 108, 118, 128, 139`
- `Applications/RockCloudPrint/` — `Rock.CloudPrint.Service/ProxyWorker.cs:231`
- `Rock/Utility/ZebraPrint.cs:215, 218, 245, 248`

**Blocks & front-end**
- `Rock.Blocks/CheckIn/CheckInKiosk.cs:115-119, 126-160, 131-137` (REST Key); block actions at `:979, 999, 1027, 1074, 1144, 1197, 1244, 1264, 1300, 1328, 1381, 1494, 1586, 1600, 1611, 1659`; `FamilyRegistration` at `:883, 1637, 1680`
- `Rock.Blocks/CheckIn/Config/CheckinTypeDetail.cs:536-538, 676-683`
- `Rock.Blocks/Cms/LavaApplicationContent.cs:56, 69, 79-80, 94`
- `RockWeb/Blocks/CheckIn/Config/CheckinTypeDetail.ascx.cs:436-440` (the reflection hack)
- `Rock.JavaScript.Obsidian.Blocks/src/CheckIn/checkInKiosk.obs:349-350, 460`
- `.../CheckIn/CheckInKiosk/checkInSession.partial.ts:283-289, 371, 412, 491, 525, 587, 835, 1506`
- `.../CheckIn/CheckInKiosk/utils.partial.ts:272-299`
- `.../CheckIn/CheckInKiosk/types.partial.ts:252-267`
- `.../CheckIn/CheckInKiosk/welcomeScreen.partial.obs:321-324`
- `.../CheckIn/Configuration/checkInSimulator.obs:314, 357, 405, 518, 550`

**View models**
- `Rock.ViewModels/Rest/CheckIn/` (18 files), `Rock.ViewModels/CheckIn/` (33), `Rock.ViewModels/CheckIn/Labels/` (14) — grep for `RockInternal`: **zero hits**
- `Rock.ViewModels/CheckIn/ConfigurationTemplateBag.cs`, `PersonBag.cs`, `AttendeeBag.cs`, `FamilyBag.cs`

**Lava / Helix**
- `RockWeb/Scripts/Rock/helix-script.js:1-4` (htmx 2.0.0 header) and the trailing Rock wrapper
- `Rock/Utility/Reflection.cs:~1045-1057, 168-174`
- `Rock/Model/CMS/LavaEndpoint/LavaEndpoint.cs:157`; `Rock.Enums/Cms/LavaEndpointSecurityMode.cs`
- `Rock/Cms/LavaApplicationRequestHelpers.cs:45-101`
- `Rock/Lava/Blocks/PrintZplBlock.cs:25, 51, 98-118, 131, 148, 164-176, 204`
- `Rock/Lava/Blocks/WebRequestBlock.cs:36, 72, 74, 81-88, 91-97, 100-106, 109-116, 203-207`
- `Rock/Lava/Blocks/ExecuteBlock.cs:30, 46-56, 89-92, 111-118, 120, 128, 142-145, 150-154`
- `Rock/Lava/Blocks/RockEntityBlock.cs:256, 279, 665-691`; `RockEntityModifyBlock.cs:934, 979, 1003`; `RockEntityDeleteBlock.cs:813, 833`
- `Rock/Lava/LavaHelper.cs:221-241`; `Rock/Lava/LavaEngineFactory.cs:108-123, 137-144, 156-173, 202-211`
- `Rock.Lava/Core/LavaSecurityHelper.cs:35-54`; `Rock.Lava.Shared/Core/ILavaSecured.cs:23`; `Rock.Lava.Shared/Core/LavaDataWrapper.cs:25, 42`
- `Rock/Utility/ExtensionMethods/LavaExtensions.cs:540-544`
- `Rock/Lava/Filters/LavaFilters.Person.cs:1028, 1055, 1352-1355`
- `Rock/CheckIn/CheckInPerson.cs:32`, `CheckInBlock.cs:115-155`, `KioskDevice.cs:34` (v1 Lava surface)

**Migrations**
- `Rock.Migrations/.../Version 1.16.6/202406281837177_CreateCheckInLabelModel.cs:66-82, 91-97, 101`
- `Rock.Migrations/.../Version 18.0/202505072235453_AddLavaApplications.cs:156-211, 746-757, 915-1564`

**Tree queries** (used instead of history, which is unreliable here)
- `git cat-file -e upstream/develop:Rock/Lava/Blocks/PrintZplBlock.cs` → present (upstream develop @ 2026-08-14)
- `Documentation/Fork-Local-Changes.md:35, 55, 77` — three fork-local changes, none check-in-related

### 7.2 Secondary — published documentation and community, product-level context only

**Do not let any of these override the code above.** Two notable currency problems: the Helix docs still describe an alpha/limited-beta state that the release notes and this codebase contradict, and Cloud Print appears in no release note or bulletin at all.

- Rock release notes — `rockrms.com/releasenotes` (Helix into core at v18.1, 8 Dec 2025; `{% printzpl %}` in Lava v19.1; v18.1 apiKey query-string fix; v18.3 ExecuteWrite security fix; v19.4 check-in CSS classes)
- Helix / Lava Applications docs — `community.rockrms.com/helix` and `community.rockrms.com/page/3517?slug=…` (`lava-applications`, `lava-applications/endpoints`, `lava-applications/content-block`, `lava-applications/observability`, `strategies/limitations`, `overview/security`, `overview/faq`, `overview/plugin-installation`, `overview/customizing-rock`, `overview/roadmap`). Note `helix.triumph.tech` now 301s here; `triumph.tech/helix` is a 404.
- Archived Triumph Helix docs (statement of intent) — `web.archive.org/web/20240929045300/https://helix.triumph.tech/`
- Jon Edmiston, "The Helix plugin has been moved to Rock Core", 2026-01-06 — `github.com/Triumph-Tech/Triumph-Helix/issues/25`
- Open Helix issues — `github.com/Triumph-Tech/Triumph-Helix/issues` (#3 no file upload, #14 "everything is assumed to be web", #19–#21)
- "Checking-out Check-in – NextGen", Book 42 — `community.rockrms.com/documentation/bookcontent/42/` (client printing requires the native apps; Cloud Print architecture and setup; device matching by IP/hostname; theme assertion). **No developer or API chapter exists.**
- "Next-Gen Check-In live in v16.7", 2 Jan 2025 — `community.rockrms.com/connect/next-gen-check-in` ("25 times faster"; V2 API + Obsidian; no unattended-check-in workflow)
- Rock API docs landing — `community.rockrms.com/api-docs/`; v2 Swagger UI on the v19.3.4 demo instance — `rock.rocksolidchurchdemo.com/api/v2/docs/index` (spec at `/api/v2/doc`; 1,710 paths; `api/v2/checkin` tag with 11 endpoints, none deprecated or internal-flagged; **no `securityDefinitions` at all**)
- Developer changelog v13.0–v20.0.8 — `community.rockrms.com/developer/changelog` (no v2-API or check-in-API section)
- `{% printzpl %}` Lava reference — `community.rockrms.com/lava/commands/print-zpl`
- Lava commands index — `community.rockrms.com/lava/commands` ("Commands let you do several things that can bypass the built-in security and business logic inside the code.")
- Tech bulletin, entity security under the v2 API — `rockrms.com/tech-bulletin/lava-and-entity-security-improvements`
- Tech bulletin, legacy kiosk block removal — `rockrms.com/tech-bulletin/removal-of-obsoleted-kiosk-blocks` (giving/prayer/person-update kiosks, **not** check-in)
- Rock Check-in iOS app — `apps.apple.com/us/app/rock-check-in/id879253336` ("print to printers on your local network that are not connected to the Internet")
- Native wrappers — `github.com/SparkDevNetwork/Rock-Checkin`, `github.com/SparkDevNetwork/Rock-WindowsCheckin` (one-line READMEs, no docs)
- Community recipe, kiosk auto-login via `rckipid` — `community.rockrms.com/recipes/7/auto-login-for-checkin-kiosks-windows-and-ipads` (~7 years old, pre-Next-Gen, **explicitly not endorsed by the core team**)
