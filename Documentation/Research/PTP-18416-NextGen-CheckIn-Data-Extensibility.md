# PTP-18416: Getting more data onto the NextGen check-in Family Select screen

**Audience:** Bryson, Jon, and whoever ends up building this.
**Ticket:** PTP-18416 — "AI research on a quick check-in solution"
**Measured against** this fork at `passion-19.3.4` · Rock McKinley 19.3.4 (`Directory.Build.props:12`)
**Date:** 2026-08-26

Every claim below is cited to a file and line in this working copy. Where a line is
quoted, it is quoted, not paraphrased. Where something could not be verified, it says so
and says what was tried.

---

## What was asked

**Bryson (ticket description):** "Use Claude/AI to see if we can inject some code into a
duplicate of the Next Gen check in backend that would allow us to pull desired pieces of
data during check in that is comparable to how we use lava in the existing check in
system. Work with Justin, if necessary, to determine the feasibility of adding on to the
Next Gen check in."

**Jon (comment, 2026-08-24):** "...whether or not you feel its complete? Mainly I'm okay
with taking some risk in testing out as long as we make these changes on a plugin copy,
and not to the CORE code. That way it doesn't get overwritten during fresh pulls/builds
and we grab it from our forked mono repo."

The underlying problem: on the Family Select screen a kiosk shows the family name and a
run of first names. Two families named Smith with a Jacob in each are indistinguishable.
In legacy check-in that screen was a Lava template, so fixing it was a config change.

---

## Short answer

**On Bryson's question.** You cannot inject anything into the NextGen check-in backend
from outside it. Every class in `Rock/CheckIn/v2/` that matters is `internal`, the
providers are get-only properties with no setter, there is no interface, no factory, no
registry and no DI seam, and the friend-assembly list on the `Rock` assembly is a closed
set of Spark's own projects (`Rock/Properties/AssemblyInfo.cs:19-35`). There is no
"duplicate the backend" move available. But the question turns out to be aimed at the
wrong layer, because **the data you actually want is already on the wire.**

**The thing worth knowing first:** the Family Select screen already receives a complete
`PersonBag` for every member of every matching family — age, gender, grade, birthdate,
photo, special-needs flag. The template throws all of it away and prints nick names.
Surfacing age or grade or a photo on that screen is a **frontend-only change to one `.obs`
file**. No C# change, no bag change, no code generation. That is a genuinely cheap fix and
it is not a trick — the evidence is in the verification table below.

Anything *not* already on the bags — the mailing address, an arbitrary person or family
Attribute — needs server-side work, and there is no configuration route to it. NextGen
renders no Lava on any kiosk screen. The Lava-equivalence Bryson is asking about does not
exist in v2 and cannot be recovered without new code, whoever writes it.

**On Jon's question.** Yes, a plugin can do this, and it is a real option rather than a
theoretical one — but not by touching the check-in engine. A plugin would ship its own
`RockBlockType` and its own Obsidian block, call the public
`POST /api/v2/checkin/SearchForFamilies` endpoint the way the stock kiosk already does
(`Rock.Rest/v2/CheckInController.cs:176-184`), and add its own block action for the extra
data. The cost is that it must carry a copy of the kiosk frontend — **9,805 lines across
36 files** — and maintain that copy against upstream forever.

One correction to the framing, offered plainly and not as a gotcha: **this repository is
the fork.** A change made here is not overwritten during fresh pulls or builds; it is
carried forward, and it shows up as a merge-conflict surface at each Rock upgrade. There
is an established convention here for exactly that, and the fork already carries three
such changes (`Documentation/Fork-Local-Changes.md`). The risk Jon is guarding against is
real, but its mechanism is a bad merge resolution, not an overwrite — and the plugin copy
trades that risk for a larger one: 9,805 lines that upstream will keep changing and that
nothing will ever tell you have drifted.

**Recommendation:** do the frontend-only change (Option 1). It answers the actual
complaint — telling two Smith families apart — at a cost of a few lines in one file, in a
file shape this fork already carries and CI already rebuilds. Treat the address as a
separate decision with a privacy question attached, and do not build the plugin copy
unless the frontend-only change is tried and found insufficient.

---

## Verification of the seven claims

| # | Claim | Verdict | Settled by |
|---|---|---|---|
| 1 | `FamilyBag` has exactly `Id`, `Name`, `CampusId`, `Members`; no address, no attributes | **Confirmed** | `Rock.ViewModels/CheckIn/FamilyBag.cs:31,37,43,49` |
| 2 | Populated in `DefaultSearchProvider.GetFamilySearchItemBags()` as described | **Confirmed** | `Rock/CheckIn/v2/DefaultSearchProvider.cs:188-245` |
| 3 | The template renders only `family.name` and `getFamilyMemberNames(family)` | **Confirmed** | `.../CheckInKiosk/familySelectScreen.partial.obs:13-14` |
| 4 | The full `PersonBag` already rides along on the search response, so Track A is frontend-only | **Confirmed** | `DefaultSearchProvider.cs:236` → `DefaultConversionProvider.cs:130-168` |
| 5 | Anything new needs bag + populate + codegen + template | **Confirmed, two corrections** | see below |
| 6 | `DisplayAddressOnFamilies` governs only registration, never the search screen | **Confirmed** | `TemplateConfigurationData.cs:468,713`; consumers only in `FamilyRegistration.cs` |
| 7 | `DefaultSearchProvider` is `internal`, no seam, "100% hardcoded", requires a core fork | **Partly — three corrections** | see below |

### Claim 4 in detail, because everything hangs on it

The question asked was whether the *search* path uses a trimmed projection of the person.
It does not. The query selects the whole `Person` entity:

```csharp
// Rock/CheckIn/v2/DefaultSearchProvider.cs:190-200
// Pull just the information we need from the database.
var familyMembers = familyMemberQry
    .Select( gm => new
    {
        gm.GroupId,
        GroupName = gm.Group.Name,
        gm.Group.CampusId,
        RoleOrder = gm.GroupRole.Order,
        gm.Person
    } )
    .ToList();
```

It then loads person attributes for the whole result set in one query:

```csharp
// Rock/CheckIn/v2/DefaultSearchProvider.cs:206-210
familyMembers
    .Select( fm => fm.Person )
    .DistinctBy( p => p.Id )
    .ToList()
    .LoadAttributes( Session.RockContext );
```

And it builds each member through the same conversion the rest of check-in uses:

```csharp
// Rock/CheckIn/v2/DefaultSearchProvider.cs:234-240
.Select( member => new FamilyMemberBag
{
    Person = Session.Director.ConversionProvider.GetPersonBag( member.Person ),
    IsInPrimaryFamily = true,
    FamilyId = IdHasher.Instance.GetHash( member.GroupId ),
    RoleOrder = member.RoleOrder
} )
```

`GetPersonBag` (`Rock/CheckIn/v2/DefaultConversionProvider.cs:130`) fills all seventeen
`PersonBag` properties. Two are conditional and both usually resolve:

- `BirthDate = person.BirthYear.HasValue ? person.BirthDate : null` (`:160`)
- `AbilityLevel = abilityLevel` (`:165`), non-null only when the person has an
  `AbilityLevel` attribute value
- `IsSpecialNeeds = person.GetAttributeValue( "core_SpecialNeeds" ).AsBoolean()` (`:167`)
- `PhotoUrl = person.PhotoUrl` (`:156`)

`Age`, `Gender`, `GradeFormatted`, `FullName` and the rest are set unconditionally
(`PersonBag.cs:32-132` enumerates the full set).

The generated TypeScript agrees — `familyMemberBag.d.ts:42` declares
`person?: PersonBag | null;` — and the template itself already proves the client holds the
object, because it reaches into it:

```typescript
// familySelectScreen.partial.obs:103-105
const names = family.members
    .filter(m => !!m.person?.nickName)
    .map(m => m.person?.nickName as string);
```

The Person Select screen goes further and already renders `photoUrl` from that same bag
(`personSelectScreen.partial.obs:277-281`), gated on the existing
`configuration.template?.isPhotoHidden` setting. So the pattern of "read more off the
PersonBag on a kiosk screen" is already in the product; it just was not applied to Family
Select.

**Verdict: confirmed.** Track A is frontend-only. This is the cheap option and it is real.

### Claim 5 — confirmed, with two corrections

The three-layer description is right: add the property to the bag, populate it in the
provider, regenerate the TypeScript, bind it in the template. Two things to add.

**Correction (a).** `Rock.CodeGeneration` does not run in CI. The pipeline explicitly
excludes it from the build artifact (`.github/workflows/pr-test-artifact.yml:309`) and
nothing invokes the generator. Regenerating `familyBag.d.ts` is a manual developer step on
a workstation, and the committed `.d.ts` is what everyone else builds against. If someone
adds a C# property and forgets the regeneration, the TypeScript will not know the property
exists and the template binding will fail to compile — a fast, loud failure, which is the
good case.

**Correction (b).** The cost is not the same for every kind of data. Person attributes are
*already loaded* for the whole search result at `DefaultSearchProvider.cs:206-210`, so
projecting an extra person attribute onto the bag costs no extra database round trip. A
family address does — it is a different entity (`GroupLocation` → `Location`) not touched
by the current query. That is one additional bounded query, not an N+1 (see Concerns).

### Claim 6 — confirmed

```csharp
// Rock/CheckIn/v2/TemplateConfigurationData.cs:468
public virtual RequirementLevel DisplayAddressOnFamilies { get; }
```

Populated at `:713` from the template settings blob. Every consumer is in the registration
path — `Rock/CheckIn/v2/FamilyRegistration.cs:175, 757, 784` — and it surfaces on
`RegistrationFamilyBag`, a different bag, via `EditFamilyResponseBag.cs:86` and
`Rock.Blocks/CheckIn/CheckInKiosk.cs:912`. It never touches `FamilyBag` or the search
path. Turning this setting on does nothing for the screen in question.

Worth noting for contrast: `RegistrationFamilyBag` is the one check-in bag that *does*
have both an address and an attribute channel —
`Rock.ViewModels/CheckIn/RegistrationFamilyBag.cs:44` (`AddressControlBag Address`) and
`:49` (`Dictionary<string, string> AttributeValues`). So the plumbing for "family address
on a check-in screen" exists in the product; it is wired to the add/edit-family screens
only.

### Claim 7 — partly; the wall is real but three sub-claims need correcting

**What is confirmed, and is stronger than the claim stated.** `DefaultSearchProvider` is
`internal` (`DefaultSearchProvider.cs:34`). So is `CheckInSession` (`:36`), so is
`CheckInDirector` (`CheckInDirector.cs:42`), and so is `DefaultConversionProvider`
(`:33`). A sweep of `Rock/CheckIn/v2/` found every type there `internal` bar one that is
not reachable for this purpose. The provider properties are get-only:

```csharp
// Rock/CheckIn/v2/CheckInSession.cs:102
public virtual DefaultSearchProvider SearchProvider { get; }
```

There is no setter, no interface, no abstract base, no factory and no registry. The single
constructor hard-wires them:

```csharp
// Rock/CheckIn/v2/CheckInSession.cs:138
SearchProvider = new DefaultSearchProvider( this );
```

The methods are `virtual`, which would allow subclassing — but only from inside the `Rock`
assembly or a friend of it, and even then nothing would construct your subclass. The
friend list is fixed and first-party: `Rock.AI.Agent`, `Rock.Blocks`, `Rock.CodeGeneration`,
`Rock.Migrations`, `Rock.Oidc`, `Rock.RealTime.Dynamic`, `Rock.Rest`, `Rock.Update`,
`Rock.WebStartup`, the test projects, and `DynamicProxyGenAssembly2` for Moq
(`Rock/Properties/AssemblyInfo.cs:19-35`). `Rock.Blocks` itself declares no friends. No
assembly here is strong-named — a search for `SignAssembly`, `AssemblyOriginatorKeyFile`
and `.snk` returns nothing — so *technically* a plugin could name itself `Rock.Rest` to
claim friendship. That is not a deployable idea and should not be entertained; it would
collide with the real assembly in the same `/Bin`.

**Correction (a): "no attribute list or config toggle" is too broad.** Configurable
attribute lists do exist in the v2 configuration object:

```csharp
// Rock/CheckIn/v2/TemplateConfigurationData.cs:600,621
public virtual IReadOnlyCollection<Guid> OptionalAttributeGuidsForFamilies { get; }
public virtual IReadOnlyCollection<Guid> RequiredAttributeGuidsForFamilies { get; }
```

with equivalents for adults and children (`:586-621`), populated from the
`CHECKIN_REGISTRATION_*` group-type attributes at `:734-739`. They are consumed only by
`FamilyRegistration.cs` and `CheckInKiosk.cs:542-553` — the registration path again. So
the mechanism for "administrator picks which attributes appear on a check-in screen"
already exists in v2 and is already modelled; it is scoped to registration. That matters,
because it means extending it to the search screen would follow an existing pattern rather
than inventing one.

**Correction (b): the Lava setting still exists and is still editable — it just does
nothing.** `TemplateConfigurationData` has a whole `#region Lava Template Properties`
(`:324-431`), fourteen properties, including:

```csharp
// Rock/CheckIn/v2/TemplateConfigurationData.cs:351-357
/// <summary>
/// Gets the legacy family select button lava template. This is used
/// by the WebForms blocks to render the entire button that represents
/// each family on the Family Select screen.
/// </summary>
/// <value>The family select button lava template.</value>
public virtual string FamilySelectButtonLavaTemplate { get; }
```

It is genuinely read out of configuration at runtime:

```csharp
// Rock/CheckIn/v2/TemplateConfigurationData.cs:697
FamilySelectButtonLavaTemplate = groupTypeCache.GetAttributeValue( GroupTypeAttributeKey.CHECKIN_FAMILYSELECT_LAVA_TEMPLATE ) ?? string.Empty;
```

and then referenced nowhere in v2 except two assertions in
`Rock.Tests/CheckIn/v2/TemplateConfigurationDataTests.cs:91,395`. Upstream's own check-in
v2 README files this under "Classic Check-in Settings" (`Rock/CheckIn/v2/README.md:760`)
and describes the field as "The lava template to use when rendering each family button on
the Family Select" (`:808`).

**This is a trap worth naming explicitly.** The setting is visible and editable in the
check-in configuration UI. Someone will find it, edit it, save it, and see no change on a
NextGen kiosk, with no error and no warning. If anyone has already tried that and
concluded "our config is broken," this is why.

For contrast, here is what the legacy screen did with it:

```csharp
// RockWeb/Blocks/CheckIn/FamilySelect.ascx.cs:247-251
var familySelectLavaTemplate = CurrentCheckInState.CheckInType.FamilySelectLavaTemplate;
mergeFields.Add( "FamilyMembers", familyMembersQuery );
lSelectFamilyButtonHtml.Text = familySelectLavaTemplate.ResolveMergeFields( mergeFields );
```

**Correction (c): "not a drop-a-DLL job" is right about the screen, wrong about the
data.** You cannot change *this* screen from a DLL in `/Bin`. But the family search
results themselves are reachable from outside the assembly with no internals access at
all, over a public REST endpoint — which is the finding that makes Jon's plugin question
answerable as a yes. That is the next section.

**Where Lava survives in NextGen.** To answer this precisely, because it is the heart of
Bryson's question: Lava is rendered in check-in v2 only in **label printing** and in one
**push notification**. The rendering sites are `Rock/CheckIn/v2/Labels/DefaultLabelProvider.cs:574`,
`Rock/CheckIn/v2/Labels/LabelField.cs:102`,
`Rock/CheckIn/v2/Labels/Renderers/ZplLabelRenderer.cs:513-516`, and
`Rock/CheckIn/v2/ProximityDirector.cs:101` (the proximity push message, not a kiosk
screen). **No kiosk screen in NextGen renders Lava.** There is no `[CodeEditorField]` or
Lava field on the kiosk block either — its settings are two linked pages, two booleans, a
REST key dropdown and an integer (`Rock.Blocks/CheckIn/CheckInKiosk.cs:58-89`).

---

## How the screen actually works today

Four hops, and the interesting thing is that only the last one is a problem.

**1. The kiosk frontend asks the REST API directly.** Not a block action:

```typescript
// Rock.JavaScript.Obsidian.Blocks/src/CheckIn/CheckInKiosk/checkInSession.partial.ts:491
const response = await this.http.post<SearchForFamiliesResponseBag>(this.getApiUrl("/api/v2/checkin/SearchForFamilies"), undefined, request);
```

An API key is appended as a query-string parameter (`:283-289`). The other calls in that
file go to the same controller — `FamilyMembers` (`:525`), `AttendeeOpportunities`
(`:835`), `SaveAttendance` (`:371`), `ConfirmAttendance` (`:412`), `Checkout` (`:587`).

**2. A public, stateless controller answers it.**

```csharp
// Rock.Rest/v2/CheckInController.cs:57-59
[RoutePrefix( "api/v2/checkin" )]
public sealed class CheckInController : ApiControllerBase

// Rock.Rest/v2/CheckInController.cs:176-184
[HttpPost]
[Route( "SearchForFamilies" )]
[Authenticate]
[Secured( Security.Authorization.EXECUTE_READ )]
...
public IActionResult PostSearchForFamilies( [FromBody] SearchForFamiliesOptionsBag options )
```

It builds the engine per request and throws it away:

```csharp
// Rock.Rest/v2/CheckInController.cs:213-217
var director = new CheckInDirector( _rockContext );
var session = director.CreateSession( configuration );
var families = session.SearchForFamilies( options.SearchTerm, options.SearchType, sortByCampus );
```

Note that `CheckInController` is public and `CheckInDirector` is internal — this compiles
only because `Rock.Rest` is on the friend list. A plugin assembly cannot write these three
lines.

**3. The provider builds the bags.** Quoted in full under Claim 4 above. The result set is
bounded: `var maxResults = TemplateConfiguration.MaximumNumberOfResults ?? 100;`
(`DefaultSearchProvider.cs:126`), applied as `.Take( maxResults )` at `:151`.

**4. The template prints two lines and discards the rest.**

```html
<!-- familySelectScreen.partial.obs:7-16 -->
<div class="button-list">
    <RockButton v-for="family in props.session.families"
                btnType="primary"
                class="family-button"
                :disabled="isProcessing"
                @click="onFamilyClick(family)">
        <span class="title">{{ family.name }}</span>
        <span class="subtitle">{{ getFamilyMemberNames(family) }}</span>
    </RockButton>
</div>
```

That is the whole gap. `family.members[i].person.age`, `.gradeFormatted`, `.gender`,
`.birthDate`, `.photoUrl` are all sitting in `props.session.families` in the browser,
already fetched, already parsed, and not printed.

---

## Can it be a plugin?

Taking each avenue to a definite answer.

### A. Subclass or replace `DefaultSearchProvider` from a plugin — **No**

`internal` class (`DefaultSearchProvider.cs:34`), inside an assembly whose friend list is
a closed first-party set (`Rock/Properties/AssemblyInfo.cs:19-35`). A plugin assembly
cannot name the type, let alone derive from it. The `virtual` methods are irrelevant from
outside.

### B. Inject a replacement provider through DI or a registry — **No**

There is no seam to inject into. `CheckInSession`'s providers are get-only (`:90-108`) and
assigned in the constructor (`:136-139`). `CheckInDirector.CreateSession` (`:350`) takes a
configuration object and nothing else. Rock's service registration
(`Rock/Configuration/RockApp.cs:89-96`) registers five unrelated services; no check-in
provider is registered anywhere, so there is nothing to override.

### C. Use `InternalsVisibleTo` — **No, and do not attempt it**

The list is fixed in Rock's own source and a plugin cannot add to it without editing core —
which defeats the purpose. Nothing is strong-named, so assembly-name impersonation is
technically possible and practically absurd: the plugin would have to be named after a
Spark assembly that already exists in the same `/Bin`.

### D. Ship a plugin block that reuses the stock kiosk's block actions — **No**

Cross-block action calls do work: `Rock.Rest/v2/BlockActionsController.cs` routes
`api/v2/blockactions/{pageGuid}/{blockGuid}/{actionName}` (`:98-105`, `:118-125`), resolves
the block by Guid with no ownership check (`:174-182`), and gates only on page VIEW plus
block VIEW/EDIT/ADMINISTRATE:

```csharp
// Rock.Rest/v2/BlockActionsController.cs:217-223
// Ensure the user has access to both the page and block. For
// block permissions, we accept VIEW, EDIT, or ADMINISTRATE.
// This is done on purpose so that we match the behavior of the
// page rendering, which does the same.
var canViewBlock = blockCache.IsAuthorized( Security.Authorization.VIEW, person )
    || blockCache.IsAuthorized( Security.Authorization.EDIT, person )
    || blockCache.IsAuthorized( Security.Authorization.ADMINISTRATE, person );
```

So the mechanism exists. It just does not help here, because **none of `CheckInKiosk`'s
sixteen block actions is a family search or a family select.** They are the registration
and administration surface — `EditFamily` (`:1585`), `SaveFamily` (`:1610`),
`AddIndividual` (`:1658`), `RemoveAttendee` (`:1143`) and so on
(`Rock.Blocks/CheckIn/CheckInKiosk.cs:978-1658`). The search never goes through a block
action at all; it goes to the REST controller, as shown above. There is nothing to proxy
or post-process.

### E. Ship a plugin block that calls the public check-in REST API — **Yes**

This is the answer to Jon's question. The endpoints are public, `[Authenticate]`, and
gated on `EXECUTE_READ` (`Rock.Rest/v2/CheckInController.cs:176-179`). They take and
return public `Rock.ViewModels` bags. The stock kiosk frontend is itself just an HTTP
client to them. A plugin frontend can be exactly the same client.

The full public surface, all on `Rock.Rest/v2/CheckInController.cs`: `Configuration`
(`:87`), `KioskStatus` (`:130`), `SearchForFamilies` (`:176`), `FamilyMembers` (`:235`),
`AttendeeOpportunities` (`:297`), `SaveAttendance` (`:361`), `ConfirmAttendance` (`:431`),
`Checkout` (`:496`), `DELETE PendingAttendance/{sessionGuid}` (`:548`),
`GET CloudPrint/{deviceId}` (`:579`), `ProximityCheckIn` (`:625`). They are stateless — the
session is rebuilt per request — so a plugin frontend can drive the whole check-in flow
without holding anything the server needs to remember.

And the extra data a plugin needs is reachable with entirely public API. The family address
requires no internals: `Group.GroupLocations` is public
(`Rock/Model/Group/Group/Group.cs:769`), `GroupLocation` is public
(`Rock/Model/Group/GroupLocation/GroupLocation.cs:42`), and `Location.FormattedAddress`
(`Rock/Model/Core/Location/Location.cs:446-448`) formats it. A plugin block action can
query that itself and merge it into what its own frontend renders.

Rock explicitly supports plugin blocks — the convention is in core:

```csharp
// Rock/Blocks/RockBlockType.cs:398-409
// Standard namespacing for blocks is to be one of:
// Rock.Blocks.x.y.z
// com.rocksolidchurchdemo.Blocks.x.y.z
...
return $"~/Obsidian/Blocks/{namespaces.AsDelimited( "/" )}/{fileName}.obs";
```

**And Passion has done this before.** `RockWeb/Plugins/team_passion/OscMatching/matchingTool.obs.js.map`
exists on this machine — a plugin-authored Obsidian block, built against the core Obsidian
framework, with a sourcemap that names `src/team_passion/OscMatching/matchingTool.obs` and
content that begins `<template><Block title="OSC Matching Tool">...`. So the build path is
proven at Passion, not just in theory.

**But price it honestly.** A plugin block that replaces Family Select cannot import the
stock kiosk's screens — it must copy them. The `@Obsidian/*` path aliases resolve only into
`Rock.JavaScript.Obsidian/dist/Framework/*` and `.../Framework/ViewModels/*`
(`Rock.JavaScript.Obsidian.Blocks/tsconfig.base.json:29-44`). The framework controls and
the generated bag types are importable; the kiosk's own `*.partial.obs` screens are not.
The kiosk frontend is **9,805 lines across 36 files**
(`Rock.JavaScript.Obsidian.Blocks/src/CheckIn/CheckInKiosk/` = 9,005 lines / 35 files, plus
`checkInKiosk.obs` at 800 lines). You cannot fork only the family screen, because it is one
state inside a state machine that owns the whole flow — search, family select, person
select, opportunity select, save, print, checkout.

You would also be duplicating, not extending, the kiosk block's own server side: 16 block
actions covering registration, attendee editing and label reprinting
(`Rock.Blocks/CheckIn/CheckInKiosk.cs:978-1658`).

### F. A client-side extension seam — **No**

Nothing in the kiosk frontend offers a slot, a plugin hook, a registerable renderer or a
template override. `familySelectScreen.partial.obs` is a fixed component with fixed markup.

### G. Is there an `AttributeValues` channel on any check-in bag? — **Only on registration**

`RegistrationFamilyBag.cs:49` and `RegistrationPersonBag.cs:128` each carry a
`Dictionary<string, string> AttributeValues`. `FamilyBag` and `PersonBag` do not
(`FamilyBag.cs:31-49`; `PersonBag.cs:32-132`). So there is no generic attribute channel on
the search path to smuggle data through.

### Drift against 19.3.4

Checked upstream `hotfix-19.3` and `develop` by content comparison, not history — this is a
shallow checkout where `git log` and `git merge-base` are unreliable
(`Documentation/Fork-Local-Changes.md:23-26`). `FamilyBag`, `DefaultSearchProvider` and
`familySelectScreen.partial.obs` are identical to ours. **No drift**, and no sign upstream
is building this.

`Documentation/Fork-Local-Changes.md` confirms **no check-in file is fork-local** — the
whole ledger is three changes across six files (an icon migration, the FormBuilder header
image, and a workflow person-entry layout change). Everything cited in this document is
stock upstream, so nothing here is already carrying a local patch.

---

## Options, with real costs

### Option 1 — Frontend-only: render what is already on the wire

Edit `familySelectScreen.partial.obs` to print more of the `PersonBag` it already holds.
Age, grade, gender, birthdate, photo. For example, `getFamilyMemberNames` at `:98-108`
already maps `m.person?.nickName`; the same map can emit `Jacob (8)` from `m.person?.age`.

- **Files changed:** 1
- **C# changed:** none. **Bag changed:** none. **Codegen:** none.
- **Build:** the Obsidian bundle rebuild that CI already does.
- **Merge burden:** one file added to `Fork-Local-Changes.md`. Same shape as ledger item 3
  (`entryFormPersonEntry.partial.obs`), which is a pure `.partial.obs` layout change.
- **Privacy:** age and grade on a lobby screen is a much smaller question than an address.
- **Limitation:** cannot show an address or an arbitrary Attribute — only the seventeen
  `PersonBag` fields.

**This solves the stated problem.** Two Smith families with a Jacob each are told apart by
age or grade in almost every real case.

### Option 2 — Core patch in this fork: add a field to the bag

Add e.g. `Address` to `FamilyBag.cs`, populate it in `GetFamilySearchItemBags`, regenerate
`familyBag.d.ts`, bind it in the template. Follow the existing `IsPhotoHidden` precedent
(`TemplateConfigurationData.cs:183,672`, surfaced on `ConfigurationTemplateBag.cs:105`) and
put it behind a configuration toggle rather than turning it on for everyone.

- **Files changed:** ~4-5, across three layers.
- **Codegen:** manual, on a workstation — not run by CI.
- **Merge burden:** four or five files on the ledger, spanning C#, view model and
  TypeScript. `Fork-Local-Changes.md:67-70` describes exactly this hazard for the header
  image feature: "A merge that resolves any one of them towards upstream leaves the other
  three referencing a member that no longer exists."
- **Runtime cost:** one extra bounded query per search (see Concerns).

### Option 3 — Plugin block

As analysed in avenue E. Real, and it satisfies "not core code" literally.

- **Files changed:** a new plugin project, plus a copy of ~9,805 lines / 36 files.
- **Merge burden:** none in the git sense — and that is the trap. The copy silently ages.
  Nothing in CI compares it to upstream, so a check-in fix or security change Spark ships
  in 19.4 simply does not reach the kiosk Passion actually uses, with no signal.
- **Also:** the plugin's C# must be built and deployed on its own path. The one plugin
  Obsidian block on this machine (`team_passion/OscMatching`) has its output ignored by
  `RockWeb/Plugins/.gitignore:2` and **its C# source is not in this repository** — so that
  build pipeline is not documented anywhere I could find.

### Option 4 — Ask upstream

File it with SparkDevNetwork: the family-select Lava setting is still exposed in
configuration but is dead in v2, and there is no v2 replacement. This is a legitimate gap
and worth reporting whichever option is chosen — `Fork-Local-Changes.md:51-53` sets the
precedent of reporting rather than only carrying. Timeline is not ours to control, so this
is a companion to one of the above, not a substitute.

### Recommendation

**Do Option 1.** It is one file, it is the same shape as a patch this fork already carries,
it needs no code generation, CI already rebuilds and ships it, and it answers the actual
complaint. Record it in `Documentation/Fork-Local-Changes.md` per the existing convention.

Reach for Option 2 only if a specific field is genuinely required that is not on
`PersonBag`, and treat the address as a separate decision with a privacy sign-off attached.

Do not build Option 3 for this problem. It is the right architecture for a kiosk experience
Passion wants to own outright, and it is a poor trade for adding one line of text to one
button.

---

## Concerns

**Merge burden, and the v19 cutover is in flight.** Any core change here becomes a
permanent conflict surface. `Fork-Local-Changes.md` is honest about what goes wrong:
"take theirs" on one of these files "silently reverts a fix or deletes a feature while
every test stays green" (`:11-14`), and it records that this has already happened once. The
file list there is test-enforced by `test_upgrade_diff.py`, so adding an entry is not
optional bookkeeping — CI fails if the list and the tree disagree. This is genuinely
manageable for one `.partial.obs`; it gets worse quickly across four files in three
layers.

**The Obsidian bundle must be rebuilt and shipped.** The compiled output is not in git —
`.gitignore:35` ignores `RockWeb/Obsidian/`, and the pr-test workflow says so plainly:
"The compiled .obs.js block files are NOT committed to the repo (0 tracked files under
RockWeb/Obsidian/Blocks), so without this the artifact ships a site with no Obsidian blocks
at all" (`.github/workflows/pr-test-artifact.yml:180-190`). Family Select has no bundle of
its own; it compiles into `RockWeb/Obsidian/Blocks/CheckIn/checkInKiosk.obs.js` (394 KB).
If a deploy ships C# without rebuilding that bundle, the kiosk runs the old screen and
nothing reports an error. A `.obs` change that is not rebuilt is simply invisible.

**PII on a screen in a public lobby.** This deserves a straight answer rather than a
checkbox. The Family Select screen is at kiosk height in an open room and a search for
"Smith" renders up to `MaximumNumberOfResults ?? 100` families
(`DefaultSearchProvider.cs:126`) — not just the searcher's own. Showing an **age or grade**
is low-risk and is already normal elsewhere in check-in. Showing a **home address** means a
stranger typing a common surname can read other families' addresses off a screen, including
addresses of minors. Showing a **birthdate** is a date-of-birth disclosure. If the address
is required, it should be truncated (street number and street, or city only), gated behind
a configuration toggle following the `IsPhotoHidden` pattern
(`TemplateConfigurationData.cs:183`), and signed off by whoever owns data policy — not
enabled by default. The upstream precedent is instructive: `IsPhotoHidden` defaults to
hiding photos (`.AsBoolean( true )` at `:672`).

**Layout at real family sizes.** A family here with eleven children already wraps. The
button is a flex column with a title and subtitle
(`RockWeb/Styles/Blocks/Checkin/CheckInKiosk.css:52-63`), centred on this screen
specifically (`:496-498`). `getFamilyMemberNames` joins every member with `asCommaAnd`
(`familySelectScreen.partial.obs:107`), so adding "(8)" after each of thirteen names could
push a single button past a full screen height. Whatever is added should be tested against
the largest real family in production data, and it may be better to show the adults plus a
count of children than to append to every name. Note this CSS *is* git-tracked, unlike the
bundle, so a styling fix is an ordinary change.

**Performance.** Smaller than it looks, but not zero. The search is bounded to 100 families
(`:126`, `:151`), and person attributes are already loaded in a single query for the whole
result set (`:206-210`). So an extra **person attribute** costs nothing at the database.
An **address** costs one additional query joining `GroupLocation` to `Location` for up to
100 groups — bounded, and it should be written as one set-based query, not a per-family
lookup inside the `.Select`. Written carelessly inside the projection at `:216-244`, it
becomes 100 round trips on a path that runs on every check-in at every kiosk during a
service. This is the single easiest way to turn a cheap change into an outage, and it is
avoidable by construction.

**If upstream later ships its own version.** Likely eventually, given that the family-select
Lava setting is still in the configuration UI with nothing consuming it. When it lands, our
patch and theirs will touch the same lines. A frontend-only change is a small conflict in
one file, easy to drop in favour of theirs. A four-file core patch conflicts across three
layers. A 9,805-line plugin copy does not conflict at all — it just quietly stops matching
the product, which is worse.

**One more, unprompted.** Someone will eventually edit the family-select Lava template in
check-in configuration and expect it to work, because the field is still there and still
saves. Whatever is built, that field should be labelled or documented as legacy-only, or
this ticket will be filed again next year.

---

## Sources

### In this repository

**Bags**
- `Rock.ViewModels/CheckIn/FamilyBag.cs:25,31,37,43,49`
- `Rock.ViewModels/CheckIn/FamilyMemberBag.cs:32,38,44,51`
- `Rock.ViewModels/CheckIn/PersonBag.cs:32-132`
- `Rock.ViewModels/CheckIn/RegistrationFamilyBag.cs:44,49`
- `Rock.ViewModels/CheckIn/RegistrationPersonBag.cs:128`
- `Rock.ViewModels/CheckIn/ConfigurationTemplateBag.cs:105`
- `Rock.ViewModels/CheckIn/EditFamilyResponseBag.cs:86`

**Check-in v2 engine**
- `Rock/CheckIn/v2/DefaultSearchProvider.cs:34,126,151,188-245,206-210,236`
- `Rock/CheckIn/v2/DefaultConversionProvider.cs:33,130,156,160,165,167`
- `Rock/CheckIn/v2/CheckInSession.cs:36,90,96,102,108,121,138`
- `Rock/CheckIn/v2/CheckInDirector.cs:42,56,350`
- `Rock/CheckIn/v2/TemplateConfigurationData.cs:183,243,324-431,351-357,468,586-621,672,680,697,713,734-739`
- `Rock/CheckIn/v2/FamilyRegistration.cs:175,757,784`
- `Rock/CheckIn/v2/README.md:751,760,808`
- `Rock/CheckIn/v2/Labels/DefaultLabelProvider.cs:574`
- `Rock/CheckIn/v2/Labels/LabelField.cs:102`
- `Rock/CheckIn/v2/Labels/Renderers/ZplLabelRenderer.cs:513-516`
- `Rock/CheckIn/v2/ProximityDirector.cs:101`
- `Rock.Tests/CheckIn/v2/TemplateConfigurationDataTests.cs:91,395`

**REST and blocks**
- `Rock.Rest/v2/CheckInController.cs:57,59,87,130,176-184,213-217,235,297,361,431,496,548,579,625`
- `Rock.Rest/v2/BlockActionsController.cs:98-105,118-125,174-182,217-223,246-247,277-288,381-383`
- `Rock.Blocks/CheckIn/CheckInKiosk.cs:58-89,94,542-553,912,978-1658`
- `Rock/Blocks/RockBlockType.cs:46,155,393-409`

**Frontend**
- `Rock.JavaScript.Obsidian.Blocks/src/CheckIn/CheckInKiosk/familySelectScreen.partial.obs:7-16,98-108,175,204`
- `Rock.JavaScript.Obsidian.Blocks/src/CheckIn/CheckInKiosk/personSelectScreen.partial.obs:18-23,277-281`
- `Rock.JavaScript.Obsidian.Blocks/src/CheckIn/CheckInKiosk/checkInSession.partial.ts:283-289,371,412,491,525,587,835,1506`
- `Rock.JavaScript.Obsidian/Framework/ViewModels/CheckIn/familyBag.d.ts:30-42`
- `Rock.JavaScript.Obsidian/Framework/ViewModels/CheckIn/familyMemberBag.d.ts:42`
- `Rock.JavaScript.Obsidian.Blocks/tsconfig.base.json:29-44`
- `Rock.JavaScript.Obsidian.Blocks/rollup.config.cjs`
- `RockWeb/Styles/Blocks/Checkin/CheckInKiosk.css:52-63,496-498`

**Legacy check-in, for contrast**
- `RockWeb/Blocks/CheckIn/FamilySelect.ascx.cs:247-251`
- `Rock/CheckIn/CheckinType.cs:309`

**Models used by the plugin option**
- `Rock/Model/Group/Group/Group.cs:100,769`
- `Rock/Model/Group/GroupLocation/GroupLocation.cs:42`
- `Rock/Model/Core/Location/Location.cs:446-448`

**Assembly boundaries and build**
- `Rock/Properties/AssemblyInfo.cs:19-35`
- `Rock.Blocks/Properties/AssemblyInfo.cs` (declares no `InternalsVisibleTo`)
- `Rock/Configuration/RockApp.cs:89-96`
- `Directory.Build.props:12`
- `.gitignore:35`
- `RockWeb/Plugins/.gitignore:2`
- `.github/workflows/pr-test-artifact.yml:180-190,309`
- `Documentation/Fork-Local-Changes.md:11-14,23-26,35-98,51-53,67-70,110`

### External

- Upstream Rock source, `SparkDevNetwork/Rock`, branches `hotfix-19.3` and `develop` —
  https://github.com/SparkDevNetwork/Rock — compared by file content for
  `FamilyBag.cs`, `DefaultSearchProvider.cs` and `familySelectScreen.partial.obs`. No
  differences from this fork.

No Rock community forum posts or blog posts were used.

### Not verified

- **The plugin block build pipeline at Passion.** `RockWeb/Plugins/team_passion/OscMatching/matchingTool.obs.js.map`
  is on disk and its sourcemap names `src/team_passion/OscMatching/matchingTool.obs`, but
  the file is untracked (ignored by `RockWeb/Plugins/.gitignore:2`) and **its C# source is
  not in this repository** — a grep for `OscMatching` and `matchingTool` across all `*.cs`
  returned nothing. So the plugin-block option is evidenced as far as "a plugin Obsidian
  block built against the core framework exists and runs here," and no further. How it is
  built and deployed would need to be recovered from whoever wrote it before Option 3 could
  be costed properly.
