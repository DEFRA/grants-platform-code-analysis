# Contract validation — the four recommendations, explained through GAS ↔ CW

*A companion to `Contract Validation Proposal.md`. That document's **Recommendation — four layers** table is terse. This one expands it into something you can act on, using one concrete edge — **GAS (`fg-gas-backend`) talking to Case Working (`fg-cw-backend`)** — as the worked example, with before/after code and a per-repo change list.*

> **Read-time note.** All file paths and line numbers below were checked against `main` as it stands today. Where the original proposal quoted status codes (e.g. `STATUS_APPLICATION_IN_REVIEW`, `STAGE_FC_REVIEWING`), the woodland config has since **changed** them to `STATUS_IN_REVIEW`, `STAGE_AWAITING_FC`, etc., and the Pact test data and comments still reference the old names. This document uses the current names.
>
> **Correction (following tech-lead review of the woodland path).** An earlier draft called the woodland status handling a *live bug*. It isn't. The two unmapped statuses below are **intermediate Case Working states that GAS is deliberately configured not to track** — GAS acknowledges them, holds its current status, and advances when it receives the next status it *does* map (`STATUS_IN_REVIEW` → skipped → `STATUS_AGREEMENT_GENERATING`; `STATUS_AWAITING_FC_REVIEW` → skipped → `STATUS_APPLICATION_COMPLETED`). Nothing has diverged in production. What the walk-through below actually shows is a **safeguard gap**, not an incident: the same code path swallows a *deliberate* skip and a *mistaken* omission identically, and nothing asserts which is which. That is the case for the test — kept below and reframed accordingly.

---

## 1. What connects GAS and CW

Two independent services that never share a database. They coordinate in two different ways, and **the proposal's four layers exist because only one of those two ways is currently protected.**

```
                    ┌─────────────────────── the config plane ───────────────────────┐
                    │  one grant version = several artefacts that must AGREE           │
                    │                                                                  │
   grants-config-*  │   gas.json  ─┐                              ┌─ cw.json           │
   (per grant repo) │   agreement.json ├─ published to S3 ────────┤                    │
                    │   payment.json ─┘                           └─ {grant}.yaml      │
                    └───────┬──────────────────────────────────────────┬──────────────┘
                            │ ingested at runtime                       │ ingested at runtime
                            ▼                                           ▼
                    ┌───────────────┐   CreateNewCaseCommand    ┌───────────────┐
                    │      GAS      │ ────────────────────────► │      CW       │
                    │ fg-gas-backend│   UpdateCaseStatusCommand │ fg-cw-backend │
                    │               │ ◄──────────────────────── │               │
                    └───────────────┘   CaseStatusUpdatedEvent  └───────────────┘
                          async FIFO SNS→SQS, both directions
```

- **The message edge** (bottom): GAS→CW `CreateNewCaseCommand` / `UpdateCaseStatusCommand`, and CW→GAS `CaseStatusUpdatedEvent`. Asynchronous, over FIFO SNS topics and SQS queues. **This is what Pact covers today.**
- **The config plane** (top): both services independently ingest artefacts from the *same* grant version. GAS reads `gas.json`; CW reads `cw.json`; they must agree on things like the set of statuses that can flow across the message edge. **Nothing checks this at all.**

Keep that split in mind: the four recommendations are not four flavours of the same thing. Layers 1–3 harden the message/HTTP edges; Layer 4 hardens the config plane. The two worked examples below both live on the config-plane side — one a confirmed PROD incident, one a latent safeguard gap.

---

## 2. The woodland status skip — intended behaviour, but nothing asserts it's intended

Trace a single CW→GAS status update for the **woodland** grant. The behaviour here is **correct** — the point is that its correctness is invisible to any current test, and an identical-looking *mistake* would be equally invisible.

**CW can emit this status.** `grants-config-woodland/configurations/woodland/cw/cw.json` declares, among others:

```
PHASE_PRE_AWARD:STAGE_REVIEWING_APPLICATION:STATUS_IN_REVIEW
PHASE_PRE_AWARD:STAGE_AWAITING_FC:STATUS_AWAITING_FC_REVIEW
```

**GAS deliberately does not map it.** `grants-config-woodland/configurations/woodland/gas/gas.json:158` has an `externalStatusMap` that maps only the CW statuses GAS acts on. `STATUS_IN_REVIEW` and `STATUS_AWAITING_FC_REVIEW` are intermediate Case Working states; GAS is configured to skip them and pick up at the *next* mapped status (`STATUS_AGREEMENT_GENERATING`, then `STATUS_APPLICATION_COMPLETED` — both present in the map below):

```jsonc
"externalStatusMap": {
  "phases": [{
    "code": "PHASE_PRE_AWARD",
    "stages": [{
      "code": "STAGE_REVIEWING_APPLICATION",
      "statuses": [
        { "code": "PHASE_PRE_AWARD:STAGE_REVIEWING_APPLICATION:STATUS_AGREEMENT_GENERATING", "source": "CW", "mappedTo": "…" },
        { "code": "PHASE_PRE_AWARD:STAGE_APPLICATION_AMENDMENT:STATUS_RETURNED_TO_CUSTOMER", "source": "CW", "mappedTo": "…" }
        // STATUS_IN_REVIEW and STATUS_AWAITING_FC_REVIEW are NOT here
      ]
    }, …]
  }]
}
```

**What happens when CW publishes `STATUS_IN_REVIEW`:**

1. The message lands on GAS's SQS queue and is written to the inbox. The inbox validates only that an `event` object exists — `fg-gas-backend/src/grants/models/inbox.js:7`:

   ```js
   static validationSchema = Joi.object({
     source: Joi.string().required(),
     event: Joi.object().required(),   // ← any object at all passes
     segregationRef: Joi.string().required(),
   });
   ```

2. Processing reaches `applyExternalStateChange` — `fg-gas-backend/src/grants/services/apply-event-status-change.service.js:216`:

   ```js
   if (!checkForExternalStatusMapping(grant, command.externalRequestedState, command.sourceSystem,
                                      application.currentPhase, application.currentStage)) {
     logger.info(`Acknowledged unknown transition for grantCode ${code} … to target position
                  ${command.externalRequestedState} …`);
     return;                            // ← acknowledge, hold current status, wait for the next mapped one
   }
   ```

3. Back in the inbox flow, a clean return means the message is acked and **`markAsComplete()`** runs (`inbox.js:42`). GAS holds its current status; when CW later publishes `STATUS_AGREEMENT_GENERATING` (which *is* mapped), GAS advances. For woodland this is exactly the designed jump — **no divergence.**

**The safeguard gap.** That same `return` branch is taken in two situations it cannot tell apart:

| Situation | What should happen | What actually happens |
|---|---|---|
| A status GAS is **meant to skip** (woodland's `STATUS_IN_REVIEW`) | acknowledge and hold — correct | `INFO` "Acknowledged unknown transition", ack |
| A status GAS is **meant to act on but nobody added to the map** (a future config mistake, a new grant, a rename) | fail loudly so it's fixed | *identical* — `INFO` line, ack, silently no-ops |

Nothing distinguishes intent from accident, and nothing asserts the intended set. So the risk is real but **latent and preventive**, not a current incident: the day someone ships a grant that emits a status GAS was supposed to map, it will be swallowed exactly the way the deliberate skips are, with only an `INFO` line to show for it. The fix is to make the skip set **explicit and asserted** — an allowlist that says "GAS deliberately ignores these," so anything *outside* both the map and the allowlist fails the check (this is exactly the "explicit commented allowlist entry" the proposal's PF-02 already anticipates).

> **Why Pact doesn't cover this.** Pact verifies the *shape* of a `CaseStatusUpdatedEvent` — that `currentStatus` is a `PHASE:STAGE:STATUS` string. `STATUS_IN_REVIEW` is a well-shaped string, so Pact is satisfied; it has nothing to say about whether the *value* is one GAS's config intends to handle. And GAS's provider verification runs with the persistence and domain layers mocked, so it never exercises the mapping at all. (Related cleanup the tech-lead review flagged: the woodland Pact test data and comments still use the **old** status names — worth fixing in the same pass.)

---

## 3. The confirmed incident — the application GAS accepts but downstream can't use

This one *has* bitten production. The break-glass class: **GAS accepts an application that is missing fields a *later* stage requires** — no phone number, missing address lines — and the gap only surfaces when the agreements service tries to build the legal agreement, on a real user's request, in PROD, forcing emergency permissions to fix by hand.

It is the *same shape of problem* as the woodland skip — a cross-artefact config gap that no message contract can see — but with the severity reversed: woodland is benign-and-latent, this one is confirmed-and-live. Both share a root cause and a single fix (Layer 4), which is the point of pairing them.

**The agreement declares exactly which application fields it needs.** `grants-config-water-management/configurations/water-management/gas/agreement.json` builds the agreement by pulling fields out of the submitted answers with JSONata `$.application.*` references:

```jsonc
"application": "$.input.answers",
"agreement": {
  "applicant": {
    "business": {
      "name":  "$.application.applicant.business.name",
      "address": {
        "line1": "$.application.applicant.business.address.line1",
        "line2": "$.application.applicant.business.address.line2",
        "postalCode": "$.application.applicant.business.address.postalCode"
      }
    },
    "customer": { "name": { "first": "$.application.applicant.customer.name.first", … } }
  }
}
```

That list of `$.application.*` paths **is** a machine-readable statement of "the fields agreement generation requires."

**But the grant's application schema doesn't require them.** GAS validates every submission against the `questions` JSON Schema in `grants-config-water-management/configurations/water-management/gas/gas.json:17-60`:

```jsonc
"questions": {
  "type": "object",
  "properties": {
    "applicant": {
      "type": "object",
      "properties": {
        "business":  { "type": "object" },   // ← no inner properties, nothing required
        "customer":  { "type": "object" }     // ← same
      },
      "required": ["business", "customer"]
    },
    …
  },
  "required": ["businessDetailsUpToDate", "totalEstimatedCost", "guidanceRead", "applicationConfirmation"]
  // ← "applicant" isn't even in the top-level required list
}
```

`business` is a bare `{ "type": "object" }`. An application submitting `business: {}` — no address, no phone, no name — **passes GAS validation cleanly**. GAS's runtime AJV validation (`fg-gas-backend/src/grants/services/schema-validation.service.js`, with the custom `fgSumEquals` / `fgSumMin` / `fgSumMax` keywords) enforces rules *within* an application; it has no idea what agreement generation will later read out of it.

So the application is accepted, the case progresses, and days later agreement generation dereferences `address.line1` off an object that doesn't have it. Break glass.

### Which of the four layers actually helps the break-glass incident?

This is the question you asked, and the honest answer matters:

| Layer | Helps here? | Why |
|------|:---:|-----|
| **1. Published API specs (OpenAPI/AsyncAPI)** | ✗ | Publishes the *shape* of endpoints and event payloads. It can't make GAS demand address/phone at submit time; the failure is field *completeness* for a downstream consumer, not a wire shape at an HTTP or event boundary. |
| **2. Shared message schemas** | ↕ indirect | Validates the *envelope* of the `CreateNewCase`/agreement events, not whether the accepted answers carry what a later stage needs. Only helps if you deliberately push a downstream-input contract upstream — which is really Layer 4's idea enforced at runtime. |
| **3. Message round-trips** | ✗ | Exercises transport, ordering, retries — not business-field completeness. |
| **4. Config compatibility gate** | ✅ | The `$.application.*` references in `agreement.json` are a machine-readable list of required fields. A cross-artefact check can extract them and assert each is `required` in the `questions` schema — and that a golden application survives the whole pipeline. water-management would **fail that check in CI**, before it ships. |

**So: yes, the proposal helps — but specifically through Layer 4, and only if Layer 4 is built to include this check.** The proposal's own cross-artefact script targets the woodland *status-enum* disagreement; catching your incident points the same technique at a different artefact pair. Crucially, **the platform already has the extraction move**: `grants-config-woodland/test/cw-schema-paths.test.js:12-45` walks `cw.json`, pulls every `$.payload.answers.*` reference, and asserts each **exists** in the application schema:

```js
function extractAnswerPaths(obj, found = new Set()) {
  if (typeof obj === 'string') {
    const match = obj.match(/^\$\.payload\.answers\.(.+)$/)   // ← same idea, different prefix
    if (match) found.add(match[1])
    …
  }
}
// …asserts resolveSchemaPath(schema, path) is defined
```

The fix is two small generalisations of a test that already exists and passes:
1. point it at `agreement.json` / `payment.json` too (prefix `$.application.` / `$.input.answers.`), and
2. tighten **exists** → **required** (a field the agreement reads must be `required`, not merely declarable).

That is the Layer-4 extension the proposal only gestures at, and it's the thing that turns "break glass in PROD" into "red X on a config PR."

---

## 4. Recommendation 4 — the config compatibility gate *(lead recommendation)*

**The problem it closes (G2):** a grant version is several artefacts consumed by four services, and *nothing checks the artefacts agree with each other* before they go live. Each config repo's CI runs `format:check`, `lint`, unit tests and a Docker build — none of it opens the `configurations/` directory to look at the content. Both examples above — the live break-glass incident and the latent woodland safeguard gap — are instances of this single hole.

**What the gate is:** a step that runs on every config PR (and again before a version is promoted `draft → active`), made of three kinds of check.

| Check kind | What it asserts | Catches |
|---|---|---|
| **Per-artefact schema** | `gas.json` and `cw.json` are individually well-formed against a published schema — the way `agreement.json` and `payment.json` already are. | Malformed config that today dies as a `TypeError` latched as a permanent PROD error. |
| **Cross-artefact agreement** | (a) every status `cw.json` can emit is either mapped in `gas.json`'s `externalStatusMap` or on an explicit skip allowlist; (b) every `$.application.*` field `agreement.json`/`payment.json` reads is `required` in the `questions` schema. | **woodland skip** (asserts intent) and **break-glass missing field**. |
| **Golden application** | a set of representative valid applications survives the *whole* pipeline — GAS validation → agreement generation → payment — against the published schemas. | Anything the static checks miss; a living regression suite per grant. |

**Before / after — the config repo's CI:**

```yaml
# before — grants-config-*/.github/workflows/check-pull-request.yml (today)
- run: |
    npm ci
    npm run format:check
    npm run lint
    npm test            # ← none of this opens configurations/
- name: Test Docker Image Build
  run: docker build …
```

```yaml
# after — added to grants-config-bootstrap (so future repos ship with it) and patched into each existing grant repo
- run: npm ci && npm run format:check && npm run lint && npm test
- name: Validate grant configuration        # ← new, configurations/-aware
  run: npx @defra/grants-config-validate ./configurations
    # fails the PR if:
    #   • cw.json emits a status that is neither mapped in gas.json
    #     nor on the explicit skip allowlist                    (woodland)
    #   • agreement.json reads a field questions doesn't require (break-glass)
    #   • a golden application fails end-to-end
    # the skip allowlist is the escape hatch: an explicit, commented entry
    # recording that GAS deliberately does not track a given CW status —
    # so a genuine omission (not on the list) is what fails
```

Put the step in **`grants-config-bootstrap`**'s `publish/check-pull-request.yml` (the template new config repos are scaffolded from) so every *future* repo ships with it — then patch it into each of the six existing per-grant repos, which do **not** inherit from bootstrap once created. Surface the result in **`grants-config-browser`**, which already renders published config read-only.

**Belt-and-braces at runtime (optional):** validate `gas.json` on ingest in GAS (`resolve-config-version.service.js` — matching what `agreement.json`/`payment.json` already do) and apply the existing `workflowSchema` on CW's config path (`fg-cw-backend/src/cases/repositories/workflow.repository.js:223`, where `saveFromDefinition` currently bypasses it). And GAS *could* validate each submission against the union of downstream field requirements at submit time and reject fast — turning a silent PROD failure into a clean rejection at the door. But the cheap, preventive place is the PR gate.

**This closes both cases** — the live break-glass incident *and* the latent woodland safeguard gap. It is the only one of the four layers that does, and it's the layer with no compensating control anywhere today — hence "lead recommendation."

**Ticket refs:** PF-01/PF-02 (the gate + rollout — PF-02 already anticipates the woodland skip allowlist), CGS-01/CGS-02 (runtime ingest validation), PF-08/PF-09 (promotion gate + browser surface), UI-03 (E2E asserts GAS status so an *unintended* status skip fails the suite).

---

## 5. Recommendation 2 — shared schema packages *(the core message-edge fix)*

**The problem it closes (G3, G7):** the message edge is validated by Pact tests that live *beside* each service and drift from what the code actually accepts. At the inbox itself, the payload is unchecked: `event: Joi.object().required()` (both `fg-gas-backend/src/grants/models/inbox.js:7` and `fg-cw-backend/src/cases/models/inbox.js:7`).

**The idea:** one npm package per bounded context that carries the schemas *and* a `validate()` function, imported by **both** the publisher and the consumer. This is not new — it is already in production for reporting events. `fg-gas-backend/src/agreements/events/agreement-reporting.event.js:67` throws on any event it is about to publish that fails the shared validator, and the collector throws on any inbound event that fails the *same* check:

```js
// already in prod — @defra/grants-reporting-publisher
const validate = (event) => {
  const { valid, errors } = validateReportingEvent(event);
  if (!valid) {
    throw new Error(`Invalid Agreement reporting event: ${errors.join(", ")}`);
  }
  return event;
};
```

**Apply the same shape to the GAS↔CW edge** — a new `@defra/fg-case-events` carrying schemas for `CreateNewCaseCommand`, `UpdateCaseStatusCommand` and `CaseStatusUpdatedEvent`, with the divergences the current Pact tests already encode (the FRPS bare-name vs WMG `PHASE_`/`STAGE_`/`STATUS_` status format, the required identifier set):

```js
// before — fg-gas-backend/src/grants/models/inbox.js (and the CW twin)
static validationSchema = Joi.object({
  source: Joi.string().required(),
  event: Joi.object().required(),          // any object passes
  segregationRef: Joi.string().required(),
});
```

```js
// after — both sides import the same package, validate by event type
import { validateCaseEvent } from "@defra/fg-case-events";

static validationSchema = Joi.object({
  source: Joi.string().required(),
  event: Joi.object().required(),
  segregationRef: Joi.string().required(),
}).custom((props, helpers) => {
  const { valid, errors } = validateCaseEvent(props.source, props.event);
  return valid ? props : helpers.error("any.invalid", { errors });
});
```

**How this replaces `can-i-deploy`:** compatibility stops being a broker query and becomes a property of the dependency graph. A provider can't merge a breaking schema change without a major version bump; a consumer can't merge without moving to a compatible range. Renovate raises the major as a PR, so the incompatibility surfaces as a failing build in the consumer's own repo — earlier, and without the Azure gateway workaround the current Pact publishing step needs. (Two things to fix while adopting: use semver ranges not exact `0.1.1` pins, and stop mocking the validator away in tests — both real caveats in today's reporting adoption.)

**Ticket refs:** X-01 (agree the package convention), CGS-05 (`@defra/fg-case-events`), CGS-07 (replace `event: Joi.object()`), CGS-08 (retire the GAS↔CW pacts once green).

---

## 6. Recommendation 3 — real message round-trips *(replaces mocked provider verification)*

**The problem it closes (G10):** Pact provider verification runs against `latest: true` selectors with persistence and the domain layer mocked — so FIFO ordering, segregation keys, inbox claiming, and retry behaviour are never exercised. The transport and the status-mapping domain logic are precisely what determine whether a real CW→GAS update advances GAS, is deliberately skipped, or is silently dropped — and today no test watches the whole path end to end.

**The idea, and why it's nearly free:** the real infrastructure is *already in CI*. `fg-gas-backend/compose/floci/start.d/10-setup-resources.sh` stands up the actual FIFO topics and queues on floci (a LocalStack-compatible AWS emulator), including the real cross-service bindings:

```bash
create_topic_and_queue "cw__sns__case_status_updated_fifo.fifo" "gas__sqs__update_status_fifo.fifo"
create_topic_and_queue "gas__sns__create_new_case_fifo.fifo"    "cw__sqs__create_new_case_fifo.fifo"
```

with MongoDB alongside. So a round-trip test is: **publish a real `CaseStatusUpdatedEvent` to the real topic, then assert GAS's observable outcome.**

```js
// after — a real round-trip asserting GAS's observable outcome.
// Publish a status GAS DOES map, and assert it advances:
await snsClient.send(new PublishCommand({
  TopicArn: "…cw__sns__case_status_updated_fifo.fifo",
  Message: JSON.stringify(caseStatusUpdatedEvent({ currentStatus: "PHASE_PRE_AWARD:STAGE_REVIEWING_APPLICATION:STATUS_AGREEMENT_GENERATING" })),
  MessageGroupId: `${clientRef}-${code}`,
}));

await waitFor(async () => {
  const app = await getApplicationStatus(clientRef, code);
  expect(app.currentStatus).toEqual("PHASE_PRE_AWARD:STAGE_REVIEWING_APPLICATION:STATUS_AGREEMENT_GENERATING");
});

// And the mirror case — a status GAS deliberately skips SHOULD leave it untouched:
//   publish STATUS_IN_REVIEW → assert app.currentStatus is unchanged.
// The two assertions together are what pins intended behaviour: the round-trip
// proves the skip is a skip, so an accidental omission (which would look the same
// to Pact) is caught by the Layer-4 allowlist check instead of slipping through.
```

This exercises the FIFO group ordering, the inbox claim/lock, the retry path, *and* the real status-mapping domain logic — none of which the mocked pact verification touches. It's the runtime complement to the Layer-4 static check: the gate proves the config *intends* the skip, the round-trip proves the code *honours* that intent.

**Ticket ref:** CGS-06.

---

## 7. Recommendation 1 — published API specs: REST *(OpenAPI)* and events *(AsyncAPI)*

Two kinds of published, diffable spec, one per interaction style:

- **OpenAPI** for the *synchronous* edges — the internal UIs (`fg-cw-frontend`, `fg-gas-frontend`) that have no contract tests at all, agreements-ui → GAS, and GAS → `fg-gss-pmf`.
- **AsyncAPI** for the *event* edges — including GAS↔CW itself. This is the part you asked to pull in, and it changes the earlier "least relevant to GAS↔CW" framing: an AsyncAPI spec *describes* the SNS/SQS channels and payloads on the message bus, so Layer 1 now has something to say about the event edge too. It doesn't *replace* Layer 2 there — it complements it (see "REST vs events, and how this meets Layer 2" below).

### REST — OpenAPI

**The problem it closes (G4, G5, G8):** most routes declare only `400: ValidationError` and no `200:` response schema, so a provider can change a response shape without any test noticing. `fg-cw-backend/src/cases/schemas/responses/find-workflows-response.schema.js` is a fully-written response schema with **no importer**. FGP-1227 established the pattern on the actuator routes (`response: { schema, failAction: "log" }`) but it stops there.

**The idea:** generate OpenAPI from the Joi route schemas that already exist — `hapi-swagger` is already wired into CW (`src/server/plugins/swagger.js`), land-grants-api, and grants-ui-backend already commits an `openapi.yaml`. Wire up the orphaned response schemas, publish the spec as a build artefact, and add a spec-diff check that fails a PR on a breaking change without a version bump. Consumers (the UIs) generate typed clients from it.

### Events — AsyncAPI *(pick this up across the estate)*

**It already exists in places — that's the opportunity.** Two repos publish AsyncAPI today:

- **`farming-grants-agreements-api`** generates both `docs/openapi.json` *and* `docs/asyncapi.json` as build artefacts (`scripts/generate-api-docs.js`, run from a husky pre-commit hook). The AsyncAPI (2.6.0) describes its SQS consumers and SNS publishers — channels like `sqs/gas_create_agreement`, with payload schemas.
- **`grants-config-broker`** hand-authors `src/docs/asyncapi.yaml` for its config-version notifications and serves an AsyncAPI docs UI.
- **`grants-config-browser`** already renders AsyncAPI docs (`src/server/asyncapidocs/`) — the natural place to host an **estate-wide event catalogue**.

So the ask is well-founded: make AsyncAPI a standard build artefact for every service that publishes or consumes SNS/SQS events (GAS, CW, agreements, payments, the reporting pipeline), diff it in CI like OpenAPI, and aggregate them in `grants-config-browser` so anyone can see every channel and payload on the bus in one place.

**But adopt the *right* generation direction.** The agreements-api spec is honest about its own weakness — its description reads *"Schemas are generated from Pact contract test data"* (`docs/asyncapi-spec-from-pact.js`, `docs/asyncapi-schemas/schema-from-pact.js`). Inferring a schema from **one sample instance** means optional fields and union/variant shapes are invisible, and it couples the spec to Pact — which this whole proposal is retiring. Propagating *that* pattern estate-wide would spread a lossy, Pact-dependent artefact just as we remove Pact. This is exactly what the proposal's **CGS-12** ("invert the agreements-api spec generation — make the schema the source") calls for. So:

> **Generate AsyncAPI *from* the schema, not from a sample.** The source of truth is the Layer 2 shared package's JSON Schemas; the AsyncAPI channels `$ref` those payloads. One source, two emitted artefacts — the executable validator (Layer 2) and the published description (Layer 1) can never drift because they're built from the same schema.

### REST vs events, and how this meets Layer 2

Worth stating plainly, because AsyncAPI and the Layer 2 package look like they overlap:

| | Layer 1 spec (OpenAPI / AsyncAPI) | Layer 2 package (`@defra/fg-case-events`) |
|---|---|---|
| **What it is** | A *published description* — a diffable, human-readable catalogue of endpoints / channels + payloads | *Executable code* both sides `import` and run |
| **What it does** | Discovery, documentation, breaking-change detection via spec-diff | *Enforcement* — rejects a bad message at the real inbox boundary at runtime |
| **For GAS↔CW** | AsyncAPI *documents and diffs* the three case events | `validate()` *enforces* them on publish and receive |

They are one source of truth with two outputs: the shared package holds the schemas; **AsyncAPI is generated from them**. On the event edge Layer 2 does the enforcing and AsyncAPI does the describing + diffing; on the REST edge, where there's no shared runtime package, OpenAPI carries more of the weight (which is why the "consumer ignoring a bump" problem below bites REST hardest).

### What stops a consumer ignoring a producer's version bump?

Be honest about this — it is the real weakness of Layer 1, and the one place where retiring `can-i-deploy` genuinely loses something. A published spec is an *artefact*, not imported code: unlike a Layer 2 package (which the consumer must physically upgrade in `package.json` to receive a new schema, with Renovate raising the PR and the consumer's tests running against it), **nothing in a spec reaches into the consumer and forces it to regenerate its client.** The producer's spec-diff check lives in the *producer's* CI — it stops the producer breaking people *silently*, but it cannot compel *adoption*. A consumer that never looks at the new spec sails on and breaks at runtime when the producer deploys.

So the REST edges are protected by a layered defence, not one gate — and all of it has to be named or the removal of `can-i-deploy` is a regression:

1. **Producer spec-diff gate** — a breaking change *must* carry a major bump. Makes breaks visible and versioned; does not force adoption.
2. **Consumer-side response validation, generated from the spec** (CGS-13's typed clients/validators). The consumer validates responses against the spec version it was built against, so a producer that changed shape is caught *loudly at the consumer boundary and in its monitoring* — a detected failure, not a silent mis-parse. Detection, not prevention.
3. **Consumer CI integration test against the real producer** (or a spec-generated mock — overlaps Layer 3's round-trip environments). *This* is the actual prevention: if the deployed producer speaks the new shape and the consumer hasn't adopted, the test fails **in the consumer's own pipeline**, before deploy. Ignoring a bump now hurts at CI time, not in PROD.
4. **Additive, versioned evolution — keep the old version alive.** Don't mutate a shape; add `v2` and keep `v1` until telemetry shows no callers. `land-grants-api` already does this (a versioned `2.0.0/` controller path with its own `200: applicationValidationResponseSchemaV2`). A consumer "ignoring" the bump just keeps calling `v1` — an explicit deprecation window, not a break; the producer retires `v1` only when it can see nobody calls it.

`can-i-deploy` answered one specific question — *"can I deploy the producer now without breaking a currently-deployed consumer?"* For REST the replacement is not a single equivalent gate; it is **additive versioning** (so deploy ordering stops mattering) **plus consumer-side validation and integration tests** (so a mismatch fails CI, not PROD). Where you genuinely need a hard *"don't ship the producer until the consumer is ready"* ordering guarantee, that edge is better served by a **Layer 2 shared package than a Layer 1 spec** — which is exactly why the GAS↔CW *event enforcement* sits on Layer 2. On the event edge, then, the adoption problem is largely handled by Layer 2 (the consumer must upgrade the package to receive a new schema); AsyncAPI adds discovery and breaking-change detection on top. It's the *REST* edges — no shared runtime package — where the layered defence above is doing the real work.

**Ticket refs:** CGS-11 (generate/publish/diff OpenAPI for GAS, CW, agreements-api), CGS-12 (**invert the agreements-api AsyncAPI generation — schema as source, not Pact sample**), CGS-13 (typed clients **plus response validation** for the two UI edges), CGS-03 (extend the response-schema pattern to `src/cases/routes/*`). *New, implied by this section:* make AsyncAPI a standard generated artefact for every event-publishing/consuming service and aggregate them as an estate-wide catalogue in `grants-config-browser`.

---

## 8. How the four layers replace Pact — nothing is lost

| Pact capability today | Replaced by | Better because |
|---|---|---|
| Message shape assertions (GAS↔CW) | **Layer 2** shared schema package | One source of truth imported by both sides, not a copy that drifts; validates at the real inbox boundary, not only in a test. |
| Provider verification | **Layer 3** real round-trips | Runs against real SNS/SQS/Mongo instead of mocked persistence + domain. |
| HTTP consumer contracts | **Layer 1** OpenAPI + spec-diff + consumer-side validation | Generated from the code, versioned, diffed in CI; no Azure-gateway publishing hack. *Weaker than Layer 2 on forcing adoption — see §7; relies on additive versioning + consumer CI tests.* |
| Event documentation / discovery | **Layer 1** AsyncAPI (generated from the Layer 2 schemas) | New: a diffable, estate-wide catalogue of every SNS/SQS channel + payload. Complements Layer 2 (which enforces); already exists in agreements-api and the broker. |
| `can-i-deploy` release gate | **doesn't exist today** — nothing to lose | For message edges, compatibility becomes a property of the dependency graph (semver + Renovate). For REST edges there is no single equivalent gate — additive versioning + consumer integration tests stand in (§7). |
| — (config plane, uncovered) | **Layer 4** config gate | Brand-new capability; the only layer that covers the config plane — the live break-glass incident and the latent woodland gap alike. |

`can-i-deploy` is worth a specific note: no repo calls it, records a deployment, or tags a version to an environment — verified by grep across all nine repos. So "losing" it costs nothing; the broker's one defining capability is already unused.

---

## 9. What changes, by repo

**`grants-config-bootstrap`** *(do first — covers every *future* repo; existing repos are patched separately)*
- Add the `configurations/`-aware validation step to `publish/check-pull-request.yml`. `[PF-01]`

**`grants-config-*` (six per-grant repos)**
- Patch the step into each existing repo (no inheritance from bootstrap once created). woodland fails first run on the unmapped statuses; fix `externalStatusMap` or add an explicit allowlist entry. water-management fails on the unrequired address/name fields; tighten the `questions` schema. `[PF-02]`
- Generalise `test/cw-schema-paths.test.js`: cover `agreement.json`/`payment.json`, and assert **required** not merely **exists**.

**`fg-gas-backend`**
- Validate `gas.json` on the S3 ingest path (`resolve-config-version.service.js`), matching `agreement.json`/`payment.json`. `[CGS-01]`
- Replace `event: Joi.object()` at the inbox with per-type validation from `@defra/fg-case-events`. `[CGS-07]`
- Add a GAS↔CW round-trip test against the existing floci stack. `[CGS-06]`

**`fg-cw-backend`**
- Apply the existing `workflowSchema` on the config path (`workflow.repository.js:223`, `saveFromDefinition`). `[CGS-02]`
- Same inbox change as GAS. `[CGS-07]`
- Wire up the orphaned `find-workflows-response.schema.js`; extend the actuator response-schema pattern to `src/cases/routes/*`. `[CGS-03]`

**New — `@defra/fg-case-events`**
- Schemas + `validate()` for the three case events, porting today's Pact assertions (status-format divergence, required identifiers). Semver ranges, Renovate raising majors. `[X-01, CGS-05]`
- Emit AsyncAPI channels/payloads *from* these schemas, so the published event spec and the runtime validator share one source.

**`farming-grants-agreements-api` (and every event-publishing/consuming service)**
- Invert the AsyncAPI generation: `docs/asyncapi.json` is currently derived from Pact sample data (`docs/asyncapi-spec-from-pact.js`) — regenerate it from the schema instead, so optionals/unions aren't lost and it doesn't depend on Pact. `[CGS-12]`
- Make `npm run generate-api-docs`-style OpenAPI+AsyncAPI generation a standard build artefact across GAS, CW, payments and the reporting pipeline; diff both in CI.

**`grants-config-browser`**
- Aggregate every service's published AsyncAPI into one estate-wide event catalogue (it already renders AsyncAPI docs). Pair with the config validation status from §4.

**Retire (only once every edge above is green)**
- Remove the GAS↔CW pacts. `[CGS-08]` Then the broker. `[X-02]`

---

### If you take one thing from this

The message edge (Pact's home) was never where the pain was. The one confirmed PROD incident — break-glass missing-field applications — and the one latent gap — the woodland status skip that works today but that no test asserts is *intentional* — are both **config-plane** problems: artefacts from the same grant version that must agree, with nothing checking that they do (or recording, where they deliberately don't). That is **Layer 4**, it has no compensating control today, and the extraction machinery to build it is already sitting in a passing test. Start there.
