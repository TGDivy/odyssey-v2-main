# Master specification implementation audit

This is the living implementation audit for
`docs/Odyssey_Master_Specification_2026-08-15.md`. It is intentionally stricter
than a feature list: a schema, route declaration, or UI placeholder is not
treated as implemented behavior. Update this file in the same commit that
changes a requirement's status.

Snapshot reviewed: current `main` on 2026-08-16.

## Status vocabulary

| Status | Meaning |
| --- | --- |
| `verified` | Implemented and exercised by an automated check in this repository. |
| `implemented` | Implemented, but its final platform or live-environment proof is owner-only. |
| `partial` | A real vertical slice exists, but normative behavior or proof is missing. |
| `contract-only` | Typed model/schema/event exists without the required behavioral loop. |
| `documented` | Product policy or operating procedure exists; no runtime claim is implied. |
| `deferred` | Deliberately disabled by the specification's sequencing rules. |
| `missing` | Required implementation or artifact does not yet exist. |

Owner-only evidence means a repository implementation exists but this Linux
environment cannot truthfully prove signing, Apple framework behavior, cloud
deployment, external account configuration, or physical-device behavior.

## Specification section audit

| Spec scope | Status | Repository evidence | Required next proof or implementation |
| --- | --- | --- | --- |
| §§1–5 product thesis, Constitution, premise, research consequences | `documented` | `docs/constitution.md`, `docs/ASSUMPTIONS.md`, master specification | Add automated copy/invariant checks where behavior becomes executable. |
| §6 good-life model | `partial` | deliberate owner-only immutable Charter revisions, optimistic supersession/history, provenance/ledger/outbox, as-of context resolution, local-only typed drafts, editable commission seed, semantic review, offline acceptance ceremony and immutable native history | Direction service, explicit recommendation citations, Xcode proof and owner-lived Charter. |
| §7 life-stage and season model | `partial` | owner-reviewed descriptive life-stage versions; Charter-bound typed season editor, legal terminal state machine, hash-bound frozen outgoing summary, optional accepted/skipped retrospective, explicit successor drafts, local-first acceptance, immutable history, terminal conflict UI and accepted-history-only season map | Direction service, Xcode and two-device proof. |
| §8 ontology and knowledge model | `partial` | provenance, temporal, assertion, event, person and relationship contracts; simple food presets have validated create/revise/tombstone projections and durable `FoodOccurrence` record/correct/void snapshots preserve preset revision, total nutrients, zone and UTC offset; all four food lifecycle events are registered | Broader admission, supersession, graph derivation, contradiction, redaction, retrieval, and event-consumer services. |
| §9 decision architecture | `partial` | decision contracts/events, B.5 immutable context-bound preparation and B.7 idempotent recommendation feedback/event-only assertion supersession with exact durable-change reporting | Full lifecycle/choice/outcome service, future-learning correction consumption, replay and product UI. |
| §10 temporal consequence engine | `partial` | versioned bounded graph traversal with time/depth/path limits, cycle/accumulation controls, uncertainty propagation, causal-status preservation, correlated-path collapse and deterministic ranking | Domain rule registry, direct-effect services, calibration reports, persistence, APIs, narrative/UI and historical replay suite. |
| §11 intent/intervention engine | `partial` | deterministic versioned silence/delivery policy plus B.6 owner-only evaluation of synced opportunities/intents, global pause, delivery-time client state, durable budgets and immutable audit | Opportunity generation, scheduling, response/outcome learning and platform delivery surfaces. |
| §12 memory architecture | `partial` | immutable ledger/projections, capture/archive contracts, source-linked interpretation/review, protected opaque local-only attachment objects with conservative staged-to-ledger recovery, bounded protected ephemeral provider-import buffering, selected-only iPhone photo/file ingestion, explicit five-minute foreground-only voice ingestion, rebuild/export tools and immutable context snapshots | Media lifecycle/tombstones, normalized admission, retrieval plans, contradiction, condensation, forgetting/redaction and broader source annotation services. |
| §13 personal learning | `partial` | experiment contracts plus C.6 sample/multiplicity/missingness/temporal/confounder/robustness/context/safety promotion policy | Durable hypothesis/preregistration workflow, analysis runner, replication, preference drift and owner review. |
| §14 scientific evidence | `partial` | source/claim/appraisal contracts plus B.8 deterministic quality-filtered citation retrieval, counterevidence search, applicability, explicit uncertainty and immutable query replay | Curated ingestion/appraisal workflow, source update/retraction jobs, broader synthesis and evidence UI. |
| §15 score philosophy | `partial` | Constitution prohibits universal Life Score/people ranking; optional C.5 qualitative day-alignment policy is disabled by default, non-scalar, coverage/exception/comparison guarded and canonical-history independent | Owner-approved experiment flag, product surface and longitudinal harm/usefulness evaluation only if deliberately enabled. |
| §16 AI philosophy | `contract-only` | provider-neutral model-run contract plus durable coalesced native capture-interpreter boundary and conservative explicit-prefix fallback | Capability router, provider execution, structured fallbacks, refusal/uncertainty, model-run provenance, evaluations and rollback. |
| §17 trust and agency | `partial` | deterministic authority policy, B.7 append-only recommendation correction, and source-inspectable stable/idempotent Archive accept/correct/dismiss review | Trust Center, future correction retrieval, revocation UI and autonomous-action audit UI. |
| §18 experience architecture | `partial` | iPhone quiet Now, explicit text/voice/photo/file capture, local-first ranked food quick-log/create/correct/void source with payload-free monotonic warm-path instrumentation and ephemeral owner result, forensic capture-detail Archive, typed reviewed life-model Workshop, accepted Season landscape/plain-language Map, sync/repair surfaces, and deterministic guilt-free re-entry contract | Tomorrow Map, rendered re-entry, decision/evidence flows, physical warm-path proof, Xcode accessibility and complete platform depth. |
| §19 visual and art direction | `partial` | calm SwiftUI/Canvas regional prototype, deterministic qualitative paths/terrain/landmarks, complete plain-language alternative, native shells and shared assets | Theme tokens, richer prototype, atlas/world states, snapshots, Xcode accessibility and dogfood proof. |
| §20 Apple ecosystem | `partial` | iOS/Watch/macOS shells, widgets/intents/share targets, portable data/auth/sync packages, guarded local AVFoundation voice capture, selected-only PhotosUI capture, system file import, permission-gated Odyssey-owned food HealthKit writes, protected extension commands, App Intents, widget/Control Center routing, crash-idempotent iPhone drains, and a protected receipt-bound WatchConnectivity text/food outbox with expiring ranked presets | Prove App Intents/WidgetKit/controls/WatchConnectivity/HealthKit on devices; add incremental health reads, EventKit/location and validation. |
| §21 integrations | `deferred` | entitlements and adapter seams only | Implement consented adapters incrementally; keep OAuth/webhooks/provider credentials disabled. |
| §22 data architecture | `partial` | append-only ledger, projections, provenance contracts, streaming SHA-256, bounded protected provider-import buffering, protected opaque local attachment manifests plus tested filesystem/ledger handoff and reconciliation, encrypted owner export/import foundations, accepted life-model history and 17 migrations | Attachment tombstone/retention lifecycle, complete semantic services, selective memory, redaction and scale budgets. |
| §23 backend architecture | `partial` | FastAPI modular monolith, Postgres/SQLite support, worker/outbox, auth/sync/attachments, accepted `/v1/seasons/*` commands/history and deterministic context assembly | Remaining domain modules and Appendix B routes, queues/workflows and operational SLO evidence. |
| §24 AI/model architecture | `contract-only` | model-run schema | Provider-neutral router, tool boundaries, prompt defense, eval gates, budget and rollback control. |
| §25 offline/synchronization | `verified` | server sync service, simulated clients, conflicts, native GRDB queue/coordinator, convergence tests, and native-shaped food-preset disjoint/overlap merge plus pull-materialization regressions | Xcode/device multi-device proof remains owner-only. |
| §26 notification/background | `partial` | background refresh/widget/intent targets plus deterministic C.1/B.6 expiry, pause, burden and delivery-state policy | Local scheduling, rendered redaction, receipts/outcomes and physical-device tests. |
| §27 observability | `partial` | structured payload-safe logging, OpenTelemetry runtime, alerts/IaC, record trace | Deploy collectors/dashboards and prove external alert delivery. |
| §28 product telemetry/self-improvement | `contract-only` | product-event/change-proposal contracts and runtime redaction | Declared-question registry, approved metrics, proposal review, counterexamples, rollback experiments. |
| §29 evaluation framework | `partial` | strict provider-neutral contracts/schemas, SHA-256 manifest, 20 synthetic stress cases, eight anchored hard-fail rubrics, six real-policy golden adapters, focused tests and deterministic evaluation gate | Private historical replay, open-ended model grading, retrieval/scientific/security/performance/UI datasets, shadow evaluation and longitudinal reports. |
| §30 security model | `partial` | owner auth, Keychain use, envelope encryption, secrets/IAM/KMS IaC, runbooks | Current threat model, penetration review, live least-privilege audit, lost-device/revocation drill. |
| §31 durability/migrations | `partial` | append-only history, Alembic/GRDB migrations, backups, restore/integrity tools | Fixture migration matrix, deployed PITR/retention proof, clean-room restore evidence. |
| §32 failure modes/pre-mortem | `partial` | kill switches, retry/conflict diagnostics, incident/recovery runbooks | Regression scenarios for each severe failure and owner drills. |
| §33 technology choices | `documented` | master specification, ADR 0001, lockfiles, OpenTofu and XcodeGen manifests | Add ADRs whenever implementation departs from selected architecture. |
| §34 repository architecture | `verified` | monorepo layout, portable paths, package/infra/docs/tool boundaries | Keep directory contract synchronized as editions are added. |
| §35 testing strategy | `partial` | 215 backend tests pass at 86.67% coverage, 135 portable Swift 6.1 tests pass, and deterministic policy golden replay plus schema/fixture/IaC checks pass in this Linux snapshot | Clear repository-wide formatter drift; historical/model, UI, physical performance, broader fault, Apple integration and live recovery suites remain. |
| §36 deployment architecture | `implemented` | GCP OpenTofu, deployment workflow examples, migration/canary/rollback and handoff docs | Owner provisions accounts, imports secrets, deploys, validates alerts/backups/restore and signs apps. |
| §37 development environments | `verified` | lockfiles, Compose, environment diagnostics, `make verify`, Mac-only skip reporting | Fresh personal Mac proof is owner-only. |
| §38 roadmap | `partial` | Edition 0 substrate and iPhone capture/auth/sync slice | Edition 1–4 product loops and milestone acceptance artifacts remain. |
| §§39–40 dependency graph/build order | `documented` | master specification and implementation sequence | Enforce dependencies via slice acceptance and audit updates. |
| §41 deliberate deferrals | `verified` | provider/APNs/OAuth/webhooks not enabled; limitations documented | Preserve explicit gates until prerequisite evidence exists. |
| §42 open questions | `documented` | master specification | Convert answerable questions into versioned research decisions and ADRs. |
| §43 real-world experiments | `missing` | no executable protocol artifacts | Add safe protocol templates; owner participation is required for outcomes. |
| §44 one-week protocol | `missing` | prose in master specification only | Runnable checklist, capture forms, analysis report template, stop conditions. |
| §45 one-month protocol | `missing` | prose in master specification only | Runnable protocol, milestone rubric, incident/regression intake, decision record. |
| §46 next iteration | `partial` | Edition 0 and native local-first slices follow sequence | Complete remaining named outputs and acceptance evidence. |
| §47 implementation-agent handoff | `partial` | README, assumptions, architecture docs, runbooks, detailed owner handoff | Maintain final requirement ledger and unresolved credential/manual-step register. |
| §48 scenario stress tests | `partial` | all 20 scenarios encoded as strict synthetic §29.2 cases with frozen context, data scope, acceptable/unacceptable outputs, evidence, authority, rubrics and provenance | Execute and grade applicable model/product/Apple surfaces; retain owner-only historical regressions privately. |
| Appendix A domain contracts | `verified` | Pydantic contracts and generated JSON Schemas | Behavioral validation still belongs to each owning section above. |
| Appendix B API/events | `verified` | error/auth/capture/sync/attachment/system routes, B.4–B.8 behavioral APIs, B.9 encrypted asynchronous signed/resumable owner exports, and immutable event registry including food-preset create/revise | Preserve contract compatibility as product surfaces consume the APIs. |
| Appendix C policies | `verified` | C.1–C.7 are versioned deterministic pure policies with focused boundary/replay-style automated tests; C.5 is disabled by default | Cross-policy golden scenarios remain tracked under §29 rather than policy implementation. |
| Appendix D sources | `documented` | cited research and official-source register | Record source-version/update policy in evidence implementation. |
| Appendix E traceability/definition of done | `partial` | this audit plus master traceability table | Close every unchecked E.2 row with automated or owner evidence. |

## Roadmap milestone audit

| Milestone | Status | Acceptance summary |
| --- | --- | --- |
| 0.1 repository and skeleton | `verified` | Credential-free stack, deterministic generation, CI/configuration and environment diagnostics exist. |
| 0.2 local ledger/projections | `partial` | Durable ledger/rebuild/export exist; 10-year performance and every-version migration matrix are not yet proven. |
| 0.3 cloud core/sync | `verified` | Auth, sync, attachments, conflicts and convergence/fault tests exist; live cloud proof is owner-only. |
| 0.4 durability/observability | `implemented` | Tools/runbooks/IaC exist; isolated live restore and external alert evidence are owner-only. |
| 1.1 Charter/Season Workshop | `implemented` | Server acceptance/history/context loop, typed local draft ledger/editors, editable seed, semantic review ceremony, immutable native history, frozen outgoing summaries, optional retrospectives, explicit successor flow, offline queue, authenticated delivery, terminal conflict guidance and accepted-history-only plain/Canvas map exist; Xcode/accessibility and two-device proof remain owner-only. |
| 1.2 capture/personal library | `partial` | Offline durable text/media capture and review, atomic food-preset lifecycle/ranking and occurrence record/correct/void, registered food events, ranked iPhone quick log with source-preserving payload-free timing, portable-tested HealthKit reconciliation, protected extension handoff, shortcuts, widget/control sheet routing, crash-idempotent iPhone drains, and protected offline Watch text/food handoff source exist | Add playback, provider interpretation and event consumption; prove App Intents/WidgetKit/WatchConnectivity/HealthKit/accessibility and the warm-path target on devices. |
| 1.3 Apple context adapters | `missing` | Targets/seams exist without real incremental HealthKit/calendar/location adapters. |
| 1.4 Now/Tomorrow Map v1 | `partial` | Quiet Now, C.7 re-entry policy and immutable deterministic model-free server context assembly exist; Tomorrow Map and rendered re-entry do not. |
| 1.5 telemetry/review | `partial` | Schemas plus payload-free ranked-food warm-path instrumentation, source/correlation dimensions, duration buckets and an ephemeral owner result exist | Declared product questions, durable consented recorder/export, broader review metrics and review loop do not. |
| 2.1 decision journal | `partial` | B.5 persistently prepares context-bound structured options/consequences and asks for missing information; choice/outcome/replay/UI loops remain. |
| 2.2 consequence engine v1 | `partial` | C.2 bounded propagation core is tested; domain rules, durable inputs/outputs, calibration, replay API and product surface remain. |
| 2.3 intent engine v1 | `partial` | C.1 silence gate, budgets, cooldown and channel policy are tested; opportunity generation/durability/delivery are absent. |
| 2.4 AI synthesis/evaluations | `deferred` | Correctly gated until deterministic context, evidence and evaluations exist. |
| 2.5 one-month dogfood | `missing` | Requires owner use and prior Edition 2 gates. |
| 3.1 evidence library | `partial` | Contracts and B.8 deterministic scoped scientific/personal query with immutable replay exist; ingestion, appraisal review, update jobs and UI remain. |
| 3.2 N-of-1 laboratory | `partial` | Contracts and conservative C.6 pattern-promotion gate exist; experiment execution, analysis, replication and review loops remain. |
| 3.3 training/nutrition depth | `deferred` | The Milestone 1.2 simple preset/ranking foundation adds no recipe/restaurant depth, recommendation, experiment, or unsafe/unsupported guidance. |
| 3.4 archive v1 | `partial` | Episode/chapter contracts plus a forensic immutable capture/interpretation lineage surface exist; temporal episodes, chapters, eras, search and synthesis remain. |
| 3.5 relationship memory | `contract-only` | Conservative person/relationship contracts only. |
| 4 meta-learning/expressive world | `deferred` | Correctly sequenced after proved lower editions. |

## Appendix E.2 closure ledger

`repo` means repository-verifiable; `owner` means evidence must be produced on
owner infrastructure/devices; `lived` means only the owner can accept the
personal state or complete the longitudinal protocol.

| Requirement | Gate | Status | Evidence or blocker |
| --- | --- | --- | --- |
| Accepted Charter, life stage and season | `lived` | `partial` | Authenticated immutable server history plus typed native editors, exact semantic review, explicit acceptance, offline delivery/cache and conflict guidance exist; Xcode proof and actual owner acceptance remain. |
| Now can intentionally show silence | `repo` | `implemented` | Quiet iPhone Now state exists; deterministic silence policy remains to connect. |
| No universal Life Score or people ranking | `repo` | `verified` | Constitution and implementation omit both. |
| Guilt-free re-entry | `repo` | `partial` | C.7 guarantees at most three current changes, one question, stale expiry, clean options, backlog suppression and no absence penalty; native rendering remains. |
| Two-line proactive copy | `repo` | `missing` | No enabled proactive copy pipeline or lint. |
| Offline local capture | `repo` | `verified` | Atomic portable/native text/media capture, protected provider-buffer handoff, crash-idempotent extension processing, and append-only owner-review tests pass; iPhone text/voice/photo/file, App Intent drain, and forensic review sources are parser-validated. |
| Common food warm path | `owner` | `implemented` | A monotonic timer accepts only durable ranked commits, counts two interactions, preserves private launch source, emits payload-free dimensions and shows one ephemeral owner result; the predeclared 40-trial physical protocol remains unexecuted. |
| Two-device convergence | `repo` | `verified` | Simulated backend/native convergence and conflict tests. |
| Migration fixtures | `repo` | `partial` | Current migrations test; full historical fixture matrix absent. |
| Intelligible owner export | `repo` | `verified` | B.9 emits signed passphrase-encrypted JSONL/CSV/Markdown ZIPs with optional raw attachments, explicit credential exclusions, immutable transition audit, retry-safe outbox processing, byte-range download, and owner verification CLI; live cloud drill remains owner-only. |
| Cloud backup/PITR enabled | `owner` | `implemented` | IaC exists; no deployment evidence. |
| Clean-room restore succeeded | `owner` | `implemented` | Tool/runbook exists; no owner execution evidence. |
| No wipe-based release step | `repo` | `verified` | Migration and rollback docs explicitly forbid routine data wipes. |
| Incremental/revocable health/calendar permissions | `owner` | `partial` | Food writes request only present energy/protein/caffeine types from an explicit action and remain local-first; HealthKit device proof plus incremental reads/calendar remain. |
| Permission denial degrades gracefully | `owner` | `partial` | Microphone and food-Health denial paths preserve local capture/logging and offer Settings; Xcode/device proof and calendar/location flows remain. |
| Cached freshness-aware widget | `owner` | `missing` | Widget target is skeletal. |
| Physical-device background proof | `owner` | `missing` | Explicitly not performed. |
| Production avoids beta-only APIs | `owner` | `partial` | Configuration targets stable SDKs; Xcode archive not performed. |
| Offline Watch quick actions | `owner` | `partial` | Protected local text/food outbox, receipt-bound immediate/background handoff, expiring ranked presets, pending UI and portable recovery tests exist; Xcode and physical two-device proof remain. |
| Deterministic model-free context | `repo` | `verified` | B.4 assembles and immutably stores source-linked domain snapshots with explicit fresh/stale/missing/denied declarations and no provider dependency. |
| Consequential model output structured/versioned | `repo` | `contract-only` | ModelRun and output contracts exist; no enabled model route. |
| Recommendation citations | `repo` | `missing` | No recommendation service. |
| Uncertainty/insufficiency outputs | `repo` | `verified` | B.5 returns explicit information requests or `insufficient_evidence` without invoking a model or fabricating paths. |
| Provider fallback | `repo` | `missing` | Providers remain disabled. |
| Prompt-injection/sensitive-route tests | `repo` | `missing` | No model pipeline/eval suite. |
| Model rollback | `repo` | `missing` | No model release system. |
| Notification budget/silence gate | `repo` | `verified` | `intent/policy.py` enforces hard gates, daily/window budgets, exponential cooldown and least-intrusive delivery with focused tests. |
| Opportunity expiry/delivery recheck | `repo` | `verified` | C.1/B.6 suppress expired opportunities and fail closed when client reports material delivery-time state change without recomputation. |
| Standing permissions visible/revocable | `repo` | `partial` | C.4 evaluates active/revoked/time-bounded/scoped grants; durable Trust Center and synced revocation UI remain. |
| External action confirmation | `repo` | `verified` | C.4 elevates risky execution and requires contemporaneous confirmation for external commits; no external executor is enabled. |
| Synced global proactive pause | `repo` | `partial` | B.6 reads the sync-converged `proactive_control` and hard-suppresses; Trust Center/native multi-device control surface remains. |
| Source/claim provenance inspectable | `repo` | `partial` | B.8 returns exact support-span/source identifiers and persists exact query replay; evidence UI and broader trace navigation remain. |
| Population/personal evidence distinct | `repo` | `verified` | B.8 returns separate scientific, personal-observation and personal-experiment collections and excludes personal records without explicit scope approval. |
| Historical replay passes | `repo` | `missing` | No cross-domain replay suite. |
| Severe failures have regressions | `repo` | `partial` | Sync/auth/restore faults covered; spec-wide scenario suite absent. |
| One-week protocol runnable | `repo` | `missing` | Prose only. |
| Telemetry answers declared questions | `repo` | `missing` | Contracts only. |
| Current threat model | `repo` | `missing` | Security design exists; dedicated dated threat model absent. |
| Secrets externalized/logs payload-safe | `repo` | `verified` | Config/IaC/Keychain patterns and logging tests. |
| Least-privilege production access | `owner` | `implemented` | IAM/IAP/service identities encoded; live audit absent. |
| Sensitive notifications redacted | `owner` | `missing` | Delivery implementation absent. |
| Incident/token/lost-device runbooks | `repo` | `partial` | Incident/account-recovery exist; dedicated lost-device/revocation flow incomplete. |
| External budget/backup alerts | `owner` | `implemented` | Alert/IaC contract exists; delivery proof absent. |
| Fresh-machine credential-free run | `repo` | `verified` | README, Compose, locks and verify flow. |
| Complete owner handoff | `repo` | `implemented` | `docs/deployment/OWNER_HANDOFF.md`; owner must fill evidence register. |
| ADRs/deviations recorded | `repo` | `partial` | Source-of-truth ADR exists; future consequential decisions need ADRs. |
| Limitations/deferrals explicit | `repo` | `verified` | README, assumptions and owner handoff distinguish unvalidated work. |
| No personal data/unmanaged credentials | `repo` | `verified` | Synthetic fixtures and secret scanning/path policy; owner must preserve this. |

## Validation baseline

At this snapshot:

- The current full backend run reports 215 tests passing at 86.67% coverage.
  Full Ruff lint and strict mypy pass across 138 source files; all changed Python
  files are format-clean. The repository-wide formatter gate still finds 16
  pre-existing drifts outside this slice, so the aggregate verification script
  stops before its remaining stages.
- Schema generation verifies 80 deterministic artifacts, synthetic-history
  generation verifies three artifacts, the evaluation corpus replays 20 cases
  through eight rubrics and six golden adapters, and the GCP structural checker
  verifies 88 resources and 29 required artifacts.
- The prior OpenTofu 1.10.6 baseline validated the deployment and all five
  mocked plans, including encrypted-export secret, storage, IAM and worker
  wiring across seventeen migrations. OpenTofu is unavailable for a current
  rerun in this environment.
- The complete portable Swift package reports 135 tests passing under the
  official Swift 6.1 release toolchain in a local Ubuntu container. This includes
  typed Workshop/editor/reducer coverage, deterministic Season map, durable
  source-linked capture interpretation, protected local attachment storage and
  filesystem/ledger recovery, bounded protected provider-import buffering and
  its durable handoff, atomic food-preset lifecycle, deterministic ranking and
  canonical merge materialization, durable food occurrence record/correct/void,
  immutable temporal/nutrient snapshots, permission-gated idempotent food-health
  reconciliation, extension crash idempotency, bounded Watch command/snapshot
  codecs and outbox recovery, monotonic payload-free food warm-path timing,
  streaming SHA-256 known answers, and
  temporal/acronym codec regressions.
- iOS, widget/control, App Intent and Watch sources, including guarded voice,
  selected-only photo/file capture, ranked food flows, HealthKit writes and
  WatchConnectivity adapters, passed Swift parser/structure validation;
  `apple/project.yml` passed YAML structure checks. SwiftUI, WidgetKit,
  AppIntents, WatchConnectivity, PhotosUI, AVFoundation and HealthKit still
  require Xcode type-checking.
- No Xcode build, signing, simulator, Apple framework integration, TestFlight,
  cloud deployment, live restore, or physical-device validation is claimed.

The authoritative owner-only evidence procedure is
`docs/deployment/OWNER_HANDOFF.md`.
