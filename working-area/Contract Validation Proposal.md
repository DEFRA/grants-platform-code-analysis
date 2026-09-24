# Grants Platform — contract validation audit

**Scope:** 34 DEFRA repositories at `main`, September 2026
**Method:** source, CI workflow and test-suite inspection, with an adversarial verification pass against every claim.

Full write-up with integration diagrams is published as an artifact: *Grants Platform Contract Validation*.

---

## Headline

The platform runs a Pact broker across nine repositories and gets much less from it than the effort implies. **No repository calls `can-i-deploy`, records a deployment, or tags a version to an environment** — verified by case-insensitive grep across every repo. Provider verification runs against `latest: true` selectors with persistence and domain layers mocked out. Nothing gates a release on contract compatibility, which is the one capability a broker exists to provide.

Meanwhile the highest-risk surface is not covered by Pact at all: grant configuration.

**And that risk is live, not theoretical.** A 40-line cross-artefact script (`contract-validation/validate-grant-config.mjs`, in the repo folder) finds inconsistencies in **2 of the 10 configured grants**:

- **woodland** — Case Working can enter `PHASE_PRE_AWARD:STAGE_FC_REVIEWING:STATUS_APPLICATION_AWAITING_FC` and `…:STATUS_APPLICATION_IN_REVIEW`. GAS declares neither, and maps neither in `externalStatusMap`.
- **pigs-might-fly** — same for `PRE_AWARD:FINAL_APPROVAL:APPLICATION_WITHDRAWN`. This is a sandbox scheme that exists to exercise the platform and will never go live, so its divergence costs nothing today. Woodland is a real grant under active development (config version 1.31.0).

When CW publishes those status updates, GAS's `mapExternalStateToInternalState` returns `{valid:false}`, `processStateTransition` returns `null`, and the inbox marks the message complete. **No exception, no warning — the update is silently discarded and the two systems' views diverge.** The Forestry Commission step is exercised by `grants-platform-e2e-tests` (`ACTION_FORWARD_TO_FC` → `STATUS_FC_REVIEW_SUCCESSFUL`) and passes, because that suite asserts on Case Working's screens and never asks GAS what status it holds.

Farm Payments and Grasslands — the two `enabledInProd` grants — are clean, so the check is not noise.

---

## Repositories in scope

Core: `grants-ui`, `grants-ui-backend`, `fg-gas-backend`, `fg-gas-frontend`, `fg-cw-backend`, `fg-cw-frontend`, `farming-grants-agreements-api`, `farming-grants-agreements-ui`, `farming-grants-agreements-pdf`, `land-grants-api`, `grants-payment-service`.

Config estate: `grants-config-broker`, `grants-config-utils`, `grants-config-bootstrap`, `grants-config-browser`, `grants-config-feature-controls`, and six per-grant repos (`grants-config-farm-payments`, `-woodland`, `-grasslands`, `-water-management`, `-land-grants`, `-example-grants`).

Reporting: `grants-reporting-collector`, `grants-reporting-processor`, `grants-reporting-publisher`, `grants-platform-metrics` (a placeholder with no integrations — exclude from the map).

Tests and stubs: `grants-platform-e2e-tests`, `grants-ui-smoke-tests`, `grants-ui-acceptance-tests` (deprecated), `grants-ui-compatibility-tests`, `grants-ui-dal-stub`, `grants-ui-gas-stub`.

Also: `fg-grants-core`, `fg-grants-platform-admin`, `fg-gss-pmf`.

---

## Coverage summary

28 integration edges catalogued: **12 contract-covered**, **1 validated by a shared schema on both sides with no contract test**, **3 one-sided or library-only**, **13 with no validation of any kind**.

Backend-to-backend edges along the lifecycle spine (grants-ui → GAS → CW → agreements → payments) are covered, and covered well. The gaps cluster in two places:

1. **Internal-facing UIs.** `fg-cw-frontend` and `fg-gas-frontend` have no `@pact-foundation/pact` dependency and no contract tests at all.
2. **Newer paths.** A contract was written for the integration that existed, not the one replacing it — agreements-ui is pact-tested against the legacy agreements API and untested against GAS; Case Working's external-endpoint pact hardcodes paths that config is free to change.

---

## Gaps (G1–G13)

| ID | Finding | Severity |
|----|---------|----------|
| G1 | No release is gated on contract compatibility — `can-i-deploy` absent everywhere | High |
| G2 | Grant config published and consumed with no compatibility check | High |
| G3 | Inbound messages stored without payload validation (`event: Joi.object()`) | High |
| G4 | Both internal UIs integrate with no contract validation; no `src/cases/*` route declares a 200-response schema | Medium |
| G5 | Agreements journey covered against legacy API only; GAS-backed path untested | Medium |
| G6 | CW external-call contracts decoupled from the config that drives them | Medium |
| G7 | Config-version SNS messages unvalidated on all four consumers | Medium |
| G8 | Specs derived from test fixtures rather than the reverse | Medium |
| G9 | External-boundary pacts (payment-hub) are mocks that will never be verified | Low |
| G10 | Message transport behaviour — FIFO, inbox/outbox, locks, retries — untested | Low |
| G11 | New integrations built outside the contract estate (reporting pipeline; contracts configured *around* the new auth scheme via `CALLER_TOKEN_ENFORCE: "false"`) | Medium |
| G12 | Feature-control YAML reaches the broker unvalidated | Medium |
| G13 | Stubs (`grants-ui-dal-stub`, `grants-ui-gas-stub`) cannot detect drift from what they stand in for | Low |

### Key evidence

- `fg-gas-backend/test/contract/verifierConfig.js:42` — `consumerVersionSelectors: [{ consumer: "grants-ui", latest: true }]`
- `land-grants-api/src/tests/contract-tests/provider.test.js` — 17 `vi.mock` calls including `findMaximumAvailableArea`, `createCompatibilityMatrix`, `validateApplication`
- `grants-ui/.github/workflows/publish.yml:85` — pacts published by hand-rolled bash+curl because "Azure Application Gateway blocks /contracts/publish"; version is `git describe --tags --abbrev=0`, so commits between tags overwrite each other
- `fg-gas-backend/src/grants/models/inbox.js:7` and `fg-cw-backend/src/cases/models/inbox.js:7` — `event: Joi.object().required()`
- `fg-cw-backend/src/cases/repositories/workflow.repository.js:223` — `saveFromDefinition` bypasses `workflowSchema`
- `grants-ui-backend/src/modules/config/config.schema.js:19` — `formDefinitionSchema` has **no production importer**; ingest validates nothing
- `fg-cw-backend` — `find-workflows-response.schema.js` has no importer; no `src/cases/routes/*` route declares a `200:` response
- Pact client drift: 5 distinct versions across 9 repos (15.0.1 → 17.1.2); CW moved 16.5.0 → 17.0.1 by Dependabot during the review
- `fg-cw-backend` FGP-1227 added five *actuator* routes with 200 response schemas — but `failAction: "log"`, and all eight `src/cases/routes/*` still declare only `400: ValidationError`

---

## The config plane (largest gap)

One grant version = **several artefacts** consumed by four services. Confirmed directly against the config repos (one repo per grant: `grants-config-farm-payments`, `-woodland`, `-grasslands`, `-water-management`, `-land-grants`, `-example-grants`):

```
configurations/{grant}/gas/gas.json           → fg-gas-backend    ❌ unvalidated
configurations/{grant}/gas/agreement.json     → fg-gas-backend    ✅ validateAgreementDefinition
configurations/{grant}/gas/payment.json       → fg-gas-backend    ✅ paymentDefinitionSchema
configurations/{grant}/grants-ui/{grant}.yaml → grants-ui-backend ❌ unvalidated
configurations/{grant}/grants-ui/allowlist.yaml → grants-ui-backend
configurations/{grant}/cw/cw.json             → fg-cw-backend     ❌ unvalidated
configurations/land-grants/actions/…          → land-grants-api   ✅ Joi (shallow)
```

Each config repo's CI runs `format:check`, `lint`, unit tests and a Docker build — **nothing opens the `configurations/` directory.** `grants-config-utils` uploads every file it finds with no content validation. `grants-config-broker` validates only the release envelope (grant, version, files, status, user). **Nothing checks that the artefacts agree with each other** — and as of today, in two grants, they do not.

GAS documents the consequence in a source comment (`resolve-config-version.service.js`): bad config is discovered in production, on a real user's request, and latched as a permanent error. The recovery mechanism is good engineering; the need for it is the gap.

---

## What is working (build on these)

1. **Real integration environments already exist.** GAS and CW run full Docker Compose stacks under Testcontainers with MongoDB and floci (a LocalStack-compatible AWS emulator), with real SNS topics and SQS queues created by `compose/floci/start.d/10-setup-resources.sh`. land-grants-api does the same with Postgres. The infrastructure for real message-contract testing is already in CI.
2. **Runtime schema validation is strong where it exists.** GAS validates applications against the grant's own JSON Schema via AJV 2020-12 with custom cross-field keywords (`fgSumEquals`, `fgSumMin`, `fgSumMax`).
3. **The proposal's core pattern is in production — twice.** `@defra/fcp-audit-publisher` carries the audit schema and `validateAuditEvent`, used by GAS, CW, grants-ui and the config broker. And `@defra/grants-reporting-publisher` does the same for reporting events with *both* sides validating: GAS throws if an event it is about to publish fails, and `grants-reporting-collector` throws on any inbound message that fails the same check. That edge has no Pact and needs none. Two fixable caveats: both consumers pin `0.1.1` exactly (use semver ranges + Renovate), and the collector's test mocks the validator away.

4. **`grants-config-bootstrap`** is the template every config repo is scaffolded from — the natural place to insert a mandatory validation step across all of them at once. **`grants-config-browser`** already renders published config read-only and is the natural place to surface validation status.

---

## Recommendation — four layers

| # | Layer | Replaces | Closes |
|---|-------|----------|--------|
| 1 | Published API specs (OpenAPI + JSON Schema), generated from existing Joi/AJV schemas, spec-diffed in CI | HTTP consumer pacts | G4, G5, G8 |
| 2 | Shared schema packages per bounded context on npm, imported by both sides, semver-gated | Message pacts | G3, G7 |
| 3 | Real message round-trips in the existing Testcontainers environments | Message provider verification | G10 |
| 4 | Config compatibility gate — per-artefact, cross-artefact and golden-application checks before `draft` → `active` | *New capability* | G2 |

**Replacing `can-i-deploy`:** nothing is lost, because it does not currently exist. Compatibility becomes a property of the dependency graph — a provider cannot merge a breaking spec change without a major bump; a consumer cannot merge without a compatible range.

**Layer 4 is half-written already.** `contract-validation/validate-grant-config.mjs` implements the cross-artefact checks — no dependencies, sub-second, exits non-zero. The per-artefact and golden-application checks need the published schemas from Layer 1.

**Why not just fix Pact?** Adding `can-i-deploy` closes G1 but none of G2, G3, G6, G7 or G10, requires fixing the Azure gateway block, and leaves the mocked-provider fidelity problem untouched. Pact's real strength is coordination between teams that cannot easily talk — different orgs, no shared registry. These are Defra teams in one GitHub org sharing `@defra/` packages on one platform. The problem Pact solves is one this estate does not have; the costs it imposes are being paid in full.

---

## Roadmap

1. **Stop the bleeding** (2–3 weeks, no Pact changes) — wire up the schemas that already exist but aren't connected: CW workflow on the S3 path, `gas.json`, `grants-ui-backend`'s orphaned `formDefinitionSchema`, per-event-type inbox validation, and extend the actuator response-schema pattern to `src/cases/routes/*`. **Run the attached cross-artefact script in every `grants-config-*` PR check — it is ready today.** Add a Joi schema for feature-control YAML. Fix the reporting collector/processor S3 prefix mismatch; delete the orphaned `grants-ui-gas-stub`.
2. **Schema packages** (4–6 weeks) — `@defra/fg-case-events` first; port the Pact consumer assertions (including the FRPS/WMG status-format divergence) into schemas; add round-trips; retire the GAS ↔ CW pacts.
3. **Config gate** (4–6 weeks, parallel) — the largest gap; start here if capacity is constrained, as it is the only gap with no compensating control anywhere.
4. **REST specs** (4–6 weeks) — generate, publish, diff; typed clients for the uncovered UI edges; invert the agreements-api spec generation.
5. **Decommission** (2 weeks) — payment-hub pact becomes a plain mock; bind CW endpoint contracts to deployed config; remove Pact from all nine repos; keep `grants-ui-smoke-tests` as the post-deploy net.

Phases 2 and 3 can run concurrently with different people. Phase 1 is independently valuable and is the natural decision point for the rest.

---

## Tickets, by team

Grouped by the team owning the repository the work lands in. Sizes: **S** a few days, **M** one to two weeks, **L** three weeks or more. IDs are placeholders. Everything in Phase 1 is independently valuable and needs no decision about Pact.

### Cross-team

| ID | Ticket | Refs | Phase | Size |
|----|--------|------|-------|------|
| X-01 | **Agree the shared schema-package convention.** One package per bounded context, schemas + `validate()` only, strict semver, internal registry, Renovate raising majors as PRs. Copy the shape of `@defra/grants-reporting-publisher`. *Done when:* written and agreed by all four teams. | G3, G7 | 2 | S |
| X-02 | **Decommission the Pact broker.** Only once every edge has a green replacement. Remove the dependency from all nine repos, delete webhook workflows, retire the broker. | G1 | 5 | S |

### Platform Framework

Owns the config estate and reporting pipeline — the largest gap and the cheapest wins. **PF-01 and PF-02 are the highest-value tickets here.**

| ID | Ticket | Refs | Phase | Size |
|----|--------|------|-------|------|
| PF-01 | **Add cross-artefact config validation to `grants-config-bootstrap`.** Put the step in the template's `check-pull-request.yml` so every config repo inherits it. Script already written. *Done when:* a deliberately broken fixture fails CI. | G2 | 1 | S |
| PF-02 | **Roll the check into all six per-grant config repos.** Depends on PF-01. Woodland and Pigs Might Fly will fail first run — each needs either an `externalStatusMap` entry or an explicit commented allowlist entry recording that GAS deliberately does not track that status. | G2 | 1 | M |
| PF-03 | **Schema for feature-control YAML, enforced in CI.** Apply in `grants-config-feature-controls`' PR check and at startup before pushing to the broker; make the duplicate-name check fail rather than log. *Done when:* a malformed control fails CI instead of throwing a `TypeError` at deploy. | G12 | 1 | S |
| PF-04 | **Fix the reporting S3 prefix mismatch.** Collector writes `reporting-events/`; processor lists `grants`. *Done when:* prefixes agree and a test asserts the hand-off. | G11 | 1 | S |
| PF-05 | **Harden `@defra/grants-reporting-publisher` adoption.** Semver ranges instead of exact `0.1.1` pins; stop mocking `validateReportingEvent` in the collector's tests. *Done when:* a breaking schema change surfaces as a failing consumer build. | G11 | 2 | S |
| PF-06 | **Publish `@defra/grants-config-events`.** Schema for the broker's config-version notification; replaces four ad-hoc attribute extractions. *Done when:* broker validates on publish, all four consumers on receipt. | G7 | 3 | M |
| PF-07 | **Validate the collector → processor S3 hand-off.** Shared schema for the blob format; replace the processor's hard-coded placeholder row mapping with real mapping validated against it. | G11 | 3 | M |
| PF-08 | **Gate draft → active promotion on validation.** Full gate — per-artefact schemas, cross-artefact checks, golden applications. Draft still deploys freely to lower environments. | G2 | 3 | L |
| PF-09 | **Surface validation status in `grants-config-browser`.** Show each version's gate result and any allowlisted divergences. | G2 | 3 | S |
| PF-10 | **Publish an OpenAPI spec for `fg-gss-pmf`.** GAS calls `POST /paymentSchedule` and stubs it by hand. *Done when:* the spec is a build artefact CGS can consume. | G4 | 4 | S |

### CGS

Owns GAS, Case Working and the agreements services — every message contract on the lifecycle spine, and the two config artefacts reaching production unvalidated.

| ID | Ticket | Refs | Phase | Size |
|----|--------|------|-------|------|
| CGS-01 | **Validate `gas.json` on the S3 ingest path.** Match what `agreement.json` and `payment.json` already do. Removes the `TypeError` path the comment in `resolve-config-version.service.js` describes. *Done when:* a malformed definition fails with a named field, not a crash latched as a permanent error. | G2 | 1 | M |
| CGS-02 | **Apply `workflowSchema` on the config-broker path in CW.** The schema exists and guards `POST /workflows`; `saveFromDefinition` bypasses it. Same schema, second call site. | G2 | 1 | S |
| CGS-03 | **Extend the actuator response-schema pattern to `src/cases/routes/*`.** FGP-1227 established it on the admin surface. Wire up the orphaned `find-workflows-response.schema.js`; revisit `failAction: "log"` once stable. | G4 | 1 | M |
| CGS-04 | **Contract coverage manifest per repo.** A checked-in list of covered edges. Prompted by agreements-ui, where eight pact tests sit beside unit tests writing to a gitignored directory. | G5 | 1 | S |
| CGS-05 | **Publish `@defra/fg-case-events`.** Port every assertion from `consumer.gas-backend.test.js` and `consumer.cw-backend.test.js` into schemas — including the FRPS bare-name vs WMG `PHASE_`/`STAGE_`/`STATUS_` divergence and the required identifier set. | G3 | 2 | L |
| CGS-06 | **Real message round-trips for GAS ↔ CW.** Publish to the real SNS topic in the existing floci stack; assert the consumer's observable outcome. Exercises FIFO ordering, segregation keys, inbox claiming, retry. | G10 | 2 | M |
| CGS-07 | **Replace `event: Joi.object()` at the inbox boundary.** Validate per event type using the CGS-05 schemas, in both GAS and CW. | G3 | 2 | M |
| CGS-08 | **Retire the GAS ↔ CW pacts.** Only once CGS-05–07 are green. The first edge off Pact. | G1 | 2 | S |
| CGS-09 | **Agreement and payment event schema packages.** Repeat CGS-05–08 for `@defra/fg-agreement-events` and `@defra/fg-payment-events` (jointly with SGS). Include the terminated and cancelled events current pacts omit. | G3 | 2 | L |
| CGS-10 | **Extend contracts to the caller-token auth scheme.** Verification runs with `CALLER_TOKEN_ENFORCE: "false"` because pacts replay requests carrying no caller token. Cover it rather than configure around it. | G11 | 2 | M |
| CGS-11 | **Generate and publish OpenAPI for GAS, CW and agreements-api.** From existing Joi route schemas; add a spec-diff check failing a PR on a breaking change without a version bump. | G4, G8 | 4 | L |
| CGS-12 | **Invert the agreements-api spec generation.** AsyncAPI and the swagger Joi schemas are inferred from one sample instance, so optional fields and unions are invisible. Make the schema the source. | G8 | 4 | M |
| CGS-13 | **Response validation for `fg-cw-frontend` and `fg-gas-frontend`.** Typed clients or validators generated from the CGS-11 specs. Closes the two entirely uncovered UI edges. | G4 | 4 | M |
| CGS-14 | **Cover the agreements-ui → GAS path.** Existing pacts name the legacy API only; `/agreements/current`, `/{id}/document`, `/{id}/actions/{action}` are untested on both sides. This is where an applicant accepts a legal agreement. | G5 | 4 | M |
| CGS-15 | **Bind CW external-endpoint contracts to deployed config.** The pact hardcodes paths workflow config can change. Validate declared `endpoints` against a registry of published specs at config-gate time. | G6 | 5 | M |
| CGS-16 | **Validate GAS → `fg-gss-pmf` against its published spec.** Depends on PF-10; replaces the hand-written stub in GAS's integration setup. | G4 | 5 | S |

### Grants-UI

Owns the applicant journey, form-definition ingest, and the E2E and smoke suites. **UI-03 is the ticket that would have caught the Woodland divergence.**

| ID | Ticket | Refs | Phase | Size |
|----|--------|------|-------|------|
| UI-01 | **Validate form definitions on ingest in `grants-ui-backend`.** Wire up the orphaned `formDefinitionSchema` and validate the body against the forms-engine-plugin schema before upsert. Note grants-ui deliberately hoists page `config` out to avoid that validation — decide whether to keep the bypass or widen the schema. | G2 | 1 | M |
| UI-02 | **Delete `grants-ui-gas-stub`.** Accepts any payload, returns a fixed status, referenced by no compose file or workflow anywhere. It will pass payloads real GAS would reject. | G13 | 1 | S |
| UI-03 | **Assert GAS application status in the E2E journeys.** The Woodland journey drives `ACTION_FORWARD_TO_FC` and passes while GAS silently discards the resulting status update. Assert on `/grants/{code}/applications/{clientRef}/status` at each stage. *Done when:* the suite fails on a status divergence. | G2 | 1 | S |
| UI-04 | **Decide how `grants-platform-e2e-tests` is triggered.** Its PR test job is commented out and nothing invokes the reusable workflow, so it runs only manually from the CDP Portal. Wire a post-deploy trigger or record the decision that it stays manual. | — | 1 | S |
| UI-05 | **Archive `grants-ui-acceptance-tests`.** Its README declares it superseded, but it still builds and publishes an image on merge. | — | 1 | S |
| UI-06 | **Give `grants-ui-dal-stub` a schema.** It never parses the incoming GraphQL query, so it satisfies queries for fields the real Consolidated View has removed. Add the schema, validate queries, diff against the real DAL on a schedule. | G13 | 3 | M |
| UI-07 | **Consume published specs, retire the grants-ui pacts.** Depends on CGS-11 and UI-08. Drops the hand-rolled bash-and-curl publishing step that exists because the Azure gateway blocks `/contracts/publish`. | G1, G4 | 4 | M |
| UI-08 | **Publish an OpenAPI spec for `grants-ui-backend`.** It already commits an `openapi.yaml`; make it generated, versioned and diff-checked. | G4 | 4 | S |

### SGS

Owns land-grants-api and grants-payment-service — two providers whose Pact verification is largely verifying mocks.

| ID | Ticket | Refs | Phase | Size |
|----|--------|------|-------|------|
| SGS-01 | **Deepen the land action config schema.** It is the only service validating ingested config, but allows unknown keys and marks nearly every field optional. Tighten it; add action codes to the config gate. | G2 | 1 | S |
| SGS-02 | **Adopt `@defra/fg-payment-events`.** Joint with CGS-09. Validate inbound `payment.create` / `payment.cancel` against the shared schema; add round-trips in its own compose stack. | G3 | 2 | M |
| SGS-03 | **Publish OpenAPI for land-grants-api v1 and v2.** hapi-swagger is already wired in. Three consumers depend on this service. | G4 | 4 | M |
| SGS-04 | **Replace the mocked provider verification.** It mocks 17 modules including `findMaximumAvailableArea`, `createCompatibilityMatrix` and `validateApplication` — the engine the service exists to provide. Cover serialisation with route-level tests against the spec; leave correctness to the existing `test:db` and `test:e2e` suites. | G1 | 4 | M |
| SGS-05 | **Convert the payment-hub pact to a plain HTTP mock.** The hub is outside the estate and runs no verification, so this pact will never be verified. Keep the coverage; stop publishing it and counting it as contract coverage. | G9 | 5 | S |

---

**If only three tickets get picked up:** PF-01, PF-02 and UI-03. Between them they add the config gate, apply it to every grant, and make the end-to-end suite capable of noticing when GAS and Case Working disagree — a few days of work against the failure this document opens with.