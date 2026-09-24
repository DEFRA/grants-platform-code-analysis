# Adding new grants-ui config is hard to coordinate across repos

**Status:** Draft for agreement — describing the problem only, not proposing solutions yet.
**Date:** 2026-09-23
**Worked example:** TGC-1634 "configurable consent guidance" — now merged
(grants-ui #1267, grants-config-grasslands #105, grants-config-example-grants #192).

## One-line summary

A single logical change — "the SSSI/HEFER consent guidance links on the
select-actions page come from config instead of being hardcoded" — had to be made
across three repositories (the app + two config repos) and could not go green in one
step. The grants-ui PR reads config from the **latest released config _tag_**, so the
app change could only pass acceptance and merge **after** the config field was not
just merged but **released** in each config repo. That ordering across repos and
release steps is the friction.

## What actually shipped (TGC-1634)

- **grants-ui #1267** (merged 2026-09-15 19:58) changed **only**
  `src/server/land-grants/views/select-actions.html` (plus its unit test and
  `docs/FEATURES.md`). It reads two links from per-page config
  (`page.def.metadata.pageConfig[<path>].links.sssi_consent` / `.sfi_hefer`) and
  **falls back to plain text with no link** when the href is absent. The added unit
  test asserts both the configured case and the no-link fallback.
- **grants-config-grasslands #105** and **grants-config-example-grants #192** (both
  merged 2026-09-15 ~16:13) add the matching block to the `/select-actions-for-land-parcel`
  page:
  ```yaml
  config:
    links:
      sfi_hefer: { href: https://www.gov.uk/.../#how-to-request-an-sfi-hefer }
      sssi_consent:{ href: https://www.gov.uk/.../#sssi-consent }
  ```
  example-grants carries it too because the in-repo grants-ui acceptance suite runs
  against the example grant.

**Scope is narrow — worth stating clearly to avoid confusion:** this only covers the
_flat_ select-actions page. The consent-required page, the grouped-action hints, and
the `SSSI_CONSENT_LINK` / `HEFER_LINK` constants in
`consent.view-model.js` / `action.view-model.js` are **still hardcoded** and were
deliberately left out of scope (FEATURES.md says so explicitly).

## Why it needed careful sequencing — how CI sources code and config

1. **App under test = the PR branch.** grants-ui is built from the PR and run locally
   in CI (`tools/run-acceptance-tests.sh` → `docker-compose-smoke-test.sh`).
2. **Config = the latest released _tag_ of each config repo — not a branch, and not
   just "merged to main".** `tools/setup-local-config.sh` resolves config with
   `resolve_latest_tag` (GitHub tags API, `tags[0]`); the GAS-schema fetch does the
   same. Config repos release via **changesets**, so merging to `main` does not by
   itself create the tag the acceptance run consumes.
3. **The grasslands/woodland acceptance suites run as latest published images**
   (`compose.tests.yml`, `pull_policy: always`) — effectively their `main`, not the
   PR under review. (Only the in-repo `grants-ui-acceptance-tests` suite is built from
   the PR.)

So the grants-ui PR cannot see a config change until it has been **merged _and_
released** in the config repo(s).

## The evidence: the merge order was forced (all 2026-09-15)

| Time         | Event                                                   |
| ------------ | ------------------------------------------------------- |
| 13:45        | grants-ui #1267 opened                                  |
| 16:13        | grasslands config #105 merged                           |
| 16:14        | example-grants config #192 merged                       |
| **16:16:40** | example-grants **3.18.1** released — field now in a tag |
| **16:16:51** | grasslands **0.23.3** released — field now in a tag     |
| 16:33        | grants-ui #1267 approved                                |
| **19:58**    | grants-ui #1267 merged                                  |

The config field had to be **released to a tag (~16:16)** before the grants-ui PR
could reliably go green and merge (**19:58**). The app change with its no-link
fallback is what makes this possible at all: without the fallback, grants-ui `main`
and the config tag could never be updated in a consistent order.

## The problem, stated for agreement

> A config-backed field in grants-ui is one logical change spread across the app and
> one or more config repos. Because the acceptance run consumes config from the
> **latest released tag**, the app PR can only
> pass and merge **after** the config field has been merged **and released** in every
> relevant config repo. Getting there requires a designed-in fallback (so an
> unconfigured state is valid) plus manual cross-repo sequencing and release timing —
> which is fiddly, easy to get wrong, and multiplies with the number of config repos
> (grasslands, woodland, example-grants, …) that must carry the same field.

Please confirm this matches your experience (especially the tag/release timing in
point 2 and the table) before we discuss options.
