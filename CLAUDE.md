# DEFRA multi-service analysis workspace

This folder is a **workspace for cross-service analysis** of the DEFRA Farming &
Countryside grants platform. It is a git repo in its own right, but the many
`DEFRA/*` subdirectories are **independent service repos** cloned alongside it —
they are things to read and reason about, not part of this repo.

## What is tracked here vs. not

Tracked in this repo: `scripts/`, `skills/`, `working-area/`, `repos.txt`,
`CLAUDE.md`, `README.md`. **Everything else is git-ignored** — the `.gitignore`
ignores `/*` and re-includes only those paths, so every cloned service repo (and
any new one) is ignored automatically.

- `repos.txt` — source of truth for which service repos belong in this workspace.
- `scripts/clone-all.sh` — clone any missing repos from the manifest.
- `scripts/update-all.sh` — safely fast-forward each repo to latest `main`.
- `working-area/` — where analysis output (notes, proposals, findings) lives.
- `skills/` — workspace-level skills for cross-service analysis.

## Conventions for Claude

- Do work **from this folder**; dip into the service repos as needed for context.
- Never commit inside a service repo, or push/PR against one, unless explicitly
  asked — those repos have their own homes on GitHub.
- Put analysis you produce in `working-area/` (or a subfolder), not in a service repo.
- Treat `repos.txt` as the canonical list of services; if you reference a service
  that isn't there, flag it.

## Platform map (orientation for analysis)

- **Applicant UI**: `grants-ui`, `grants-ui-backend`, plus stubs
  (`grants-ui-dal-stub`, `grants-ui-gas-stub`) and test suites
  (`grants-ui-acceptance-tests`, `-smoke-tests`, `-compatibility-tests`,
  `-grasslands-tests`, `-woodland-tests`).
- **Grant application service (GAS)**: `fg-gas-backend`, `fg-gas-frontend`.
- **Casework (CW)**: `fg-cw-backend`, `fg-cw-frontend`.
- **Agreements**: `farming-grants-agreements-api`, `-ui`, `-pdf`.
- **Land**: `land-grants-api`, `land-grants-api-tests`.
- **Grants config**: `grants-config-*` (broker, browser, utils, bootstrap,
  feature-controls, example-grants, and per-scheme: farm-payments, grasslands,
  land-grants, water-management, woodland) + `grant-config-woodland`.
- **Payments / reporting / metrics**: `grants-payment-service`,
  `grants-reporting-{collector,processor,publisher}`, `grants-platform-metrics`.
- **Core / admin / shared**: `fg-grants-core`, `fg-grants-platform-admin`,
  `fg-gss-pmf`, `grants-platform-e2e-tests`, `sfi-reform-service-e2e-tests`,
  `farming-grants-docs`, `cdp-app-config`.
