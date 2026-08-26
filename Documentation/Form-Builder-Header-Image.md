# Form Builder Header Image (PTP-14803)

How a header image gets onto a user-facing Form Builder form, what exists in
production, and the three changes that deliver it.

Investigated against production on 2026-07-30. All investigation was read-only.
Change 3 has since shipped. Change 1 is a Lava shortcode held in the database,
so confirm its state in Admin Tools rather than from this repo.

---

## How form headers work today

Form headers already render images through a **custom Lava shortcode**, not
through anything in core Rock:

| | |
|---|---|
| Shortcode | Id **43**, "Form Builder Images" |
| Tag | `{[ header ]}` (inline) |
| Enabled Lava commands | `Sql` |
| Where to edit | Admin Tools → CMS Configuration → Lava Shortcodes |

The shortcode looks up an image **by name** in a shared bank:

| | |
|---|---|
| Header Image Bank | DefinedType **408**, Guid `e1b8e6e7-8251-4f22-b098-99b77002380d` |
| Entries | `PCC Default`, `Shea's Test Image`, `PLE Header`, `US>Night` |

A form's header content calls it like this:

```liquid
{[ header image:'PCC Default' ]}
```

The form-builder template **"Generic Survey"** (Id 2) already has
`{[ header image:'PCC Default' ]}` as its `FormHeader`, so every form built on
that template invokes the shortcode automatically.

Form entry on production is served by the WebForms block
`~/Blocks/WorkFlow/WorkflowEntry.ascx`, which publishes `Workflow`, `Activity`,
and `Action` as merge fields to the header template.

### Known bug: five forms request an image that isn't in the bank

The shortcode fails silently when the requested name has no matching bank entry
— it renders nothing at all, with no error. Five forms are in that state:

| Workflow Type | Form | Requested image |
|---|---|---|
| 821 | Bryson's Form Builder Test | `Basic PCC Header` |
| 822 | Going to PowerPoint Night | `Basic PCC Header` |
| 823 | Erin's Test Form | `Test image` |
| 824 | Test Form | `Basic PCC Header` |
| 825 | Wesley's Test Form | `TestHeader` |

Most are test forms, but **822 "Going to PowerPoint Night"** may be a real form
— worth a look. The fix for any of them is either to add the missing name to
the bank, or to correct the name in the form's header, or to upload an image
directly on the form once the change below is in place.

---

## The attribute already exists in production

No provisioning is needed. The attribute the ticket asks for is already there:

| | |
|---|---|
| Attribute Id | **60265** |
| Key | `HeaderImage` |
| Name | Header Image |
| Guid | `983948ff-3d93-4e7e-a587-4a1122bff7ec` |
| Field type | **Image** (stores a `BinaryFile` Guid) |
| Entity type | `Rock.Model.WorkflowType` (no qualifier — applies to every workflow type) |
| IsSystem | False |

**No workflow type currently has a value for it.** That matters: it means the
shortcode change below is a strict no-op until someone uploads an image, so it
can be applied ahead of any form work with no visible effect.

View security: the attribute has no explicit `Auth` rules, so it inherits the
entity-type default, which is `View` → Allow → All Users. Anonymous form fillers
can see it — the same footing as the bank's own `Image` attribute, which renders
for anonymous users today.

---

## Change 1 — Extend the shortcode (no deploy needed)

Prefer an image uploaded on the form itself; fall back to the bank lookup.

**Apply this through the Rock UI**, not with a SQL `UPDATE`. Rock holds the
shortcode in `LavaShortcodeCache`; a raw SQL write does not flush that cache, so
the change would not take effect until the cache expired or the app pool
recycled. Saving through the UI flushes it.

Admin Tools → CMS Configuration → Lava Shortcodes → **Form Builder Images** →
replace the markup with:

```liquid
<style>
.form-builder-image {
    width: {{ width }};
    height: {{ height }};
    margin: {{ margin }}px {{ margin }}px {{ margin }}px {{ margin }}px;
    margin-bottom: {{ margin-bottom }}px;
    border-radius: {{ border-radius }}px;
    opacity: {{ opacity }};
}
</style>

{% comment %}
    PTP-14803. An image uploaded on the form itself (the workflow type's
    "Header Image" attribute) takes priority over the shared Header Image Bank,
    so a form can carry its own header without an admin first adding a named
    entry to the bank. When the form has no image of its own we fall back to the
    original bank lookup by name, so every existing {[ header image:'Name' ]}
    call keeps working exactly as before.
{% endcomment %}

{% assign formImage = '' %}
{% if Workflow %}
    {% assign formImage = Workflow.WorkflowTypeCache | Attribute:'HeaderImage' %}
{% endif %}

{% if formImage != '' %}

    {% assign customimage = formImage | Replace:'img-responsive','form-builder-image' %}
    {% if center == 'yes' %}<center> {% endif %}
    {{ customimage }}
    {% if center == 'yes' %}</center> {% endif %}

{% else %}

    {% sql %}
    SELECT dv.Guid AS ImageGuid
    FROM [DefinedValue] dv
    WHERE dv.DefinedTypeId = 408
    AND dv.Value = '{{ image }}'
    {% endsql %}

    {% for row in results limit:1 %}

    {% definedvalue where:'Guid == "{{ row.ImageGuid }}"' securityenabled:'false' %}
        {% for am in definedvalueItems %}

            {% assign defaultimage = am | Attribute:'Image' %}
            {% assign customimage = defaultimage | Replace:'img-responsive','form-builder-image' %}
            {% if center == 'yes' %}<center> {% endif %}
            {{ customimage }}
            {% if center == 'yes' %}</center> {% endif %}

        {% endfor %}
    {% enddefinedvalue %}
    {% endfor %}

{% endif %}
```

The pre-change markup is backed up on the web server at
`C:\Windows\Temp\shortcode43-backup.txt`. To roll back, paste that file's
contents back into the same screen.

Two different SHA256 values identify that backup — check you are comparing like
with like:

| | SHA256 |
|---|---|
| The markup **string** (UTF-8 bytes, 909 chars) | `139B5F98C42DB4CBEAA87BA63B883E0D877F3A7D0A40CBFE18132E72E9F7CA9E` |
| The backup **file** on disk (`Get-FileHash`, UTF-16 + BOM) | `5B963C52A9A959F24DC38E077E8239C6DD0D78A1121156A0B5483F53D530AAFF` |

Use the first when hashing `LavaShortcode.Markup` read from the database. The
shortcode's `ModifiedDateTime` is a simpler tell: it reads `2025-11-05` while
the shortcode is unmodified.

Why it is safe:

- Zero forms have a `HeaderImage` value, so the new branch is dead code on day one.
- The bank branch is byte-for-byte the original logic, just nested in an `{% else %}`.
- `{% if Workflow %}` guards the case where the shortcode is used outside a
  workflow context, where `Workflow` is undefined.
- `Workflow.WorkflowTypeCache` is marked `[LavaVisible]` on `Rock.Model.Workflow`,
  and the `Attribute` filter calls `LoadAttributes()` itself when they aren't
  loaded, so no extra setup is required in the template.
- A form with its own image now skips the `{% sql %}` query entirely.

Behavior change to be aware of: if a form has *both* an uploaded image and an
explicit `image:'Name'` in its header, the **uploaded image wins**. That is the
intent of the ticket, but it means uploading an image silently overrides a named
bank image on that form.

---

## Change 2 — Setting a header image from the workflow-type editor

The Form Builder Settings tab carries the upload field (Change 3). The same
attribute is also reachable from the generic workflow-type editor, which is the
fallback route when the Form Builder screen is not available:

1. Go to **Admin Tools → General Settings → Workflow Configuration**
   (`/admin/general/workflows`).
2. Find the form's category, then the form itself, and edit it.
3. In the workflow type's **Attribute Values**, set **Header Image** and upload
   the image.
4. Save.

Save through this screen rather than by SQL — the same cache reasoning applies,
`WorkflowTypeCache` needs the flush that saving performs.

Then make sure the form's header actually calls the shortcode. Either the form
is on a template whose `FormHeader` already contains `{[ header ]}`, or add this
to the form's header content:

```liquid
{[ header ]}
```

Note there is no longer any need to pass `image:'…'` — with Change 1 in place,
an image uploaded on the form is found automatically. The usual sizing
parameters still work: `{[ header width:'50%' center:'yes' margin-bottom:'20' ]}`.

### Referencing it directly instead

To place the image yourself rather than via the shortcode:

```liquid
{{ Workflow.WorkflowTypeCache | Attribute:'HeaderImage' }}
```

That renders a full `<img src='…' class='img-responsive' />` tag.

**Gotchas:**

- `| Attribute:'HeaderImage','Url'` does **not** work. `ImageFieldType` is not an
  `ILinkableFieldType`, so the `'Url'` qualifier returns nothing. Use
  `,'RawValue'` if you want the bare `BinaryFile` Guid and intend to build the
  URL yourself.
- Use `Workflow.WorkflowTypeCache`, **not** `Workflow.WorkflowType`. Both are
  `[LavaVisible]`, but on the form-entry page the workflow has not been saved
  yet, so the `WorkflowType` navigation property is `null` — `Workflow.Activate`
  sets only `WorkflowTypeId`. `WorkflowTypeCache` resolves off that id
  (`Rock/Model/Workflow/Workflow/Workflow.Logic.cs:47`) and works either way.
  Getting this wrong fails silently: the header renders nothing, no error.
- The image is uploaded as temporary and only becomes permanent when the record
  is saved. If you upload and then navigate away without saving, the nightly
  Rock Cleanup job (job Id 7, ~1:00 AM) deletes the orphaned file.

---

## Change 3 — The Settings tab field

This is the part the ticket screenshot asks for: an **Header Image** uploader on
the Form Builder → Settings tab, between "Is Login Required" and "Form Entry
Starts".

Shipped. Four files carry it:

| File | Change |
|---|---|
| `Rock.ViewModels/Blocks/WorkFlow/FormBuilder/FormGeneralViewModel.cs` | `HeaderImage` bag property |
| `Rock.JavaScript.Obsidian.Blocks/src/WorkFlow/FormBuilder/Shared/types.partial.ts` | `headerImage` on the `FormGeneral` type |
| `Rock.JavaScript.Obsidian.Blocks/src/WorkFlow/FormBuilder/FormBuilderDetail/generalSettings.partial.obs` | `ImageUploader` control + wiring |
| `Rock.Blocks/WorkFlow/FormBuilder/FormBuilderDetail.cs` | Read/write the `HeaderImage` attribute value |

It reads and writes attribute `HeaderImage` on the workflow type, guarded by
`Attributes.ContainsKey( "HeaderImage" )` so it degrades to a hidden field on any
installation that lacks the attribute.

**This cannot be hot-deployed.** Unlike the `RockWeb/Plugins/**` blocks, these
compile into `Rock.Blocks.dll` / `Rock.ViewModels.dll` and a webpack-bundled
Obsidian block, so any further change ships with a full build and deploy.

No EF migration was added, deliberately — production already has the attribute,
and a migration in core `Rock.Migrations` would collide on upstream merges. If
this ever needs to run on an installation without the attribute, provision it
there rather than in a core migration.

---

## Summary

| | Needs a build? | Effect |
|---|---|---|
| Change 1 — shortcode | No | `{[ header ]}` prefers a per-form uploaded image |
| Change 2 — set an image | No | Staff can set header images today |
| Change 3 — Settings tab | Shipped | Upload from Form Builder instead of the workflow editor |

Changes 1 and 2 together deliver what the ticket asks for, without a deploy.
Change 3 is the convenience of doing it from the Form Builder screen.
