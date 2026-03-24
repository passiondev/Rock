# Rock RMS

Open source Relationship Management System (RMS) for churches and 501c3 organizations. ASP.NET 4.5 C# web application. This is Passion City Church's fork.

## Stack

- C# / ASP.NET 4.5 WebForms
- Entity Framework 6.0
- jQuery, Bootstrap 3
- Obsidian (Vue.js-based) for newer UI blocks
- LESS for stylesheets
- SQL Server (migrations in `Rock.Migrations/`)

## Key commands

- `npm run css-lint-core` -- lint core LESS styles
- `npm run css-lint-themes` -- lint theme styles
- `npm run watch-css-core` -- watch and lint core styles
- Build via Visual Studio / `msbuild Rock.sln`

## Architecture

- `Rock/` -- core library (models, services, data access, utilities)
- `Rock.Rest/` -- REST API controllers
- `Rock.Migrations/` -- EF database migrations
- `Rock.Blocks/` -- Obsidian (Vue.js) block implementations
- `Rock.ViewModels/` -- view model DTOs for Obsidian blocks
- `Rock.Enums/` -- shared enum definitions
- `Rock.Common/` -- shared utilities
- `Rock.JavaScript.Obsidian/` -- Obsidian framework (TypeScript/Vue)
- `Rock.JavaScript.Obsidian.Blocks/` -- compiled Obsidian block JS
- `RockWeb/` -- ASP.NET WebForms site (pages, blocks, themes, scripts)
- `RockWeb/Blocks/` -- WebForms block .ascx files
- `RockWeb/Plugins/` -- third-party and org-specific plugin blocks
- `RockWeb/Plugins/org_passion/` -- Passion-specific custom blocks
- `Rock.Tests/` -- unit tests
- `Rock.Tests.Integration/` -- integration tests
- `Rock.Lava/` -- Lava templating engine (Rock's template language)

## Testing

- MSTest (`Rock.Tests/`, `Rock.Tests.Integration/`)

## Branch strategy

- `develop` is the main branch
- Feature/fix branches like `develop-17.6.1` off develop
- Upstream is SparkDevNetwork/Rock on GitHub

## Passion customizations

Custom blocks live in `RockWeb/Plugins/org_passion/` and `RockWeb/Plugins/team_passion/` covering check-in, scheduling, RSVP, CMS, finance, security, and workflow features.
