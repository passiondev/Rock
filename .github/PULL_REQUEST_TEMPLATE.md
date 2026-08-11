<!--
This is the template for internal Passion City Church work.

Contributing a fix back to core Rock (SparkDevNetwork/Rock) instead? Open your PR
with ?template=upstream-contribution.md appended to the URL to get Spark's
template, which asks for the things their maintainers need.
-->

## What changed

<!-- One or two sentences a non-engineer could follow. What did you change, and why? -->

## Ticket

<!-- Jira key, e.g. PTP-12345. Write "none" for chores with no ticket. -->

PTP-

## How to test it

<!--
Where in Rock does a reviewer go to see this? Be specific enough that someone who
did not write the change can confirm it works.

Example:
1. Go to Admin Tools > Communications > Communication Templates
2. Open "Weekend Recap"
3. The Header Image field should now appear above Body
-->

1.
2.
3.

## Deploy notes

<!-- Delete any line that does not apply. -->

- [ ] Includes a database migration
- [ ] Requires a Rock setting / block attribute change after deploy (describe it below)
- [ ] Touches a theme, stylesheet, or other file under `RockWeb/Themes`
- [ ] Safe to deploy on its own, in any order

---

<!--
### Getting a live test site for this PR

Add the `rock:start` label to this PR. CI builds the branch on a Windows
runner and deploys it to its own site at:

    https://pr-<this PR number>.rock-dev.connect.passion.team

The build takes roughly 25-35 minutes. Labels track progress:

  rock:queued -> rock:building -> rock:deploying -> rock:deployed

A comment on this PR is updated with the URL and a link to the logs. Other labels:

  rock:auto      redeploy automatically on every new push to this branch
  rock:stop      shut the site down but keep it (frees memory on the server)
  rock:destroy   delete the site entirely

The environment is destroyed automatically when this PR merges, and stopped when
it closes without merging.

Note: the test site runs against the shared sandbox database, not production.
Data you create there is not real and may be wiped by a sandbox refresh.
-->
