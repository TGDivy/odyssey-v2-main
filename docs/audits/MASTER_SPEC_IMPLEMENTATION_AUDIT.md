# Master specification implementation audit

This is the living implementation audit for
`docs/Odyssey_Master_Specification_2026-08-15.md`. It is intentionally stricter
than a feature list: a schema, route declaration, or UI placeholder is not
treated as implemented behavior. Update this file in the same commit that
changes a requirement's status.

Snapshot reviewed: current `main` on 2026-08-15.

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
| §6 good-life model | `contract-only` | `domain/life.py` Charter and direction contracts; generated schemas | Versioned owner acceptance, resolution-by-time, and recommendation linkage. |
| §7 life-stage and season model | `contract-only` | `domain/life.py`; event schemas | Immutable revision service, transition state machine, Workshop UI, replay tests. |
| §8 ontology and knowledge model | `partial` | provenance, temporal, assertion, event, person, relationship contracts; durable ledger | Admission, supersession, graph derivation, contradiction, redaction, and retrieval services. |
| §9 decision architecture | `contract-only` | `decision/models.py`; decision event and JSON schemas | Lifecycle service, preparation API, replay, UI, and recommendation audit. |
| §10 temporal consequence engine | `contract-only` | `ConsequenceCandidate` schema | Bounded propagation, causal-status preservation, deduplication, calibration, replay suite. |
| §11 intent/intervention engine | `partial` | `intent/models.py`; deterministic versioned silence/delivery policy with expiry, pause, cooldown, budget, context-recheck and channel tests | Durable opportunity service, synced pause state, scheduling, outcome loop and platform surfaces. |
| §12 memory architecture | `partial` | immutable ledger, projections, capture/archive contracts, rebuild and export tools | Admission, retrieval plans, contradiction, condensation, forgetting/redaction, source annotations. |
| §13 personal learning | `contract-only` | `evidence/experiments.py` | Pattern-assessment policy, preregistration workflow, analysis, replication, and owner review. |
| §14 scientific evidence | `contract-only` | `evidence/models.py`; source/claim/appraisal schemas | Evidence ingestion/query, appraisal policy, counterevidence, applicability, citations, updates. |
| §15 score philosophy | `documented` | Constitution prohibits universal Life Score; no ranking implementation | Optional removable day-alignment experiment with data-quality and comparison guards. |
| §16 AI philosophy | `contract-only` | `ai/models.py` | Capability router, structured fallbacks, refusal/uncertainty, provenance, evaluations, rollback. |
| §17 trust and agency | `contract-only` | standing authorization and policy-decision schemas; kill switches | Deterministic authority engine, visible/revocable permissions, correction effects, global pause. |
| §18 experience architecture | `partial` | iPhone quiet Now, capture, Archive, Workshop/repair surfaces | Tomorrow Map, decision/evidence flows, re-entry, accessibility and complete platform depth. |
| §19 visual and art direction | `partial` | native SwiftUI shells and shared assets scaffold | Tokens, map/world states, motion/accessibility treatment, snapshots, reduced-motion proof. |
| §20 Apple ecosystem | `partial` | iOS/Watch/macOS shells, widgets/intents/share targets, portable data/auth/sync packages | Real HealthKit/EventKit/location/watch/widget adapters and Xcode/device validation. |
| §21 integrations | `deferred` | entitlements and adapter seams only | Implement consented adapters incrementally; keep OAuth/webhooks/provider credentials disabled. |
| §22 data architecture | `partial` | append-only ledger, projections, provenance contracts, export/import, 10 migrations | Complete semantic services, selective memory, retention/redaction, scale budgets. |
| §23 backend architecture | `partial` | FastAPI modular monolith, Postgres/SQLite support, worker/outbox, auth/sync/attachments | Remaining domain modules and Appendix B routes, queues/workflows, operational SLO evidence. |
| §24 AI/model architecture | `contract-only` | model-run schema | Provider-neutral router, tool boundaries, prompt defense, eval gates, budget and rollback control. |
| §25 offline/synchronization | `verified` | server sync service, simulated clients, conflicts, native GRDB queue/coordinator, convergence tests | Xcode/device multi-device proof remains owner-only. |
| §26 notification/background | `partial` | background refresh coordinator and widget/intent targets | Deterministic intervention policy, local scheduling, redaction, expiry, delivery recheck, device tests. |
| §27 observability | `partial` | structured payload-safe logging, OpenTelemetry runtime, alerts/IaC, record trace | Deploy collectors/dashboards and prove external alert delivery. |
| §28 product telemetry/self-improvement | `contract-only` | product-event/change-proposal contracts and runtime redaction | Declared-question registry, approved metrics, proposal review, counterexamples, rollback experiments. |
| §29 evaluation framework | `partial` | backend/Swift tests, synthetic fixtures, CI/verify command | Golden scenarios, rubrics, model/security/replay/performance/UI evaluation artifacts. |
| §30 security model | `partial` | owner auth, Keychain use, envelope encryption, secrets/IAM/KMS IaC, runbooks | Current threat model, penetration review, live least-privilege audit, lost-device/revocation drill. |
| §31 durability/migrations | `partial` | append-only history, Alembic/GRDB migrations, backups, restore/integrity tools | Fixture migration matrix, deployed PITR/retention proof, clean-room restore evidence. |
| §32 failure modes/pre-mortem | `partial` | kill switches, retry/conflict diagnostics, incident/recovery runbooks | Regression scenarios for each severe failure and owner drills. |
| §33 technology choices | `documented` | master specification, ADR 0001, lockfiles, OpenTofu and XcodeGen manifests | Add ADRs whenever implementation departs from selected architecture. |
| §34 repository architecture | `verified` | monorepo layout, portable paths, package/infra/docs/tool boundaries | Keep directory contract synchronized as editions are added. |
| §35 testing strategy | `partial` | 106 backend tests, 45 portable Swift tests at snapshot, schema/fixture/IaC checks | Missing replay, golden, UI, performance, fault, Apple integration and live recovery suites. |
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
| §48 scenario stress tests | `missing` | isolated sync/recovery tests only | Encode every scenario as deterministic fixtures/replays plus owner-only Apple scenarios. |
| Appendix A domain contracts | `verified` | Pydantic contracts and generated JSON Schemas | Behavioral validation still belongs to each owning section above. |
| Appendix B API/events | `partial` | error envelope, auth/capture/sync/attachment/system routes; immutable event registry | Context, decision, intervention, feedback, evidence and encrypted asynchronous export APIs. |
| Appendix C policies | `partial` | C.1 deterministic silence gate and focused replay-style unit cases | Implement C.2–C.7 and the cross-policy golden replay suite. |
| Appendix D sources | `documented` | cited research and official-source register | Record source-version/update policy in evidence implementation. |
| Appendix E traceability/definition of done | `partial` | this audit plus master traceability table | Close every unchecked E.2 row with automated or owner evidence. |

## Roadmap milestone audit

| Milestone | Status | Acceptance summary |
| --- | --- | --- |
| 0.1 repository and skeleton | `verified` | Credential-free stack, deterministic generation, CI/configuration and environment diagnostics exist. |
| 0.2 local ledger/projections | `partial` | Durable ledger/rebuild/export exist; 10-year performance and every-version migration matrix are not yet proven. |
| 0.3 cloud core/sync | `verified` | Auth, sync, attachments, conflicts and convergence/fault tests exist; live cloud proof is owner-only. |
| 0.4 durability/observability | `implemented` | Tools/runbooks/IaC exist; isolated live restore and external alert evidence are owner-only. |
| 1.1 Charter/Season Workshop | `contract-only` | Contracts and a repair Workshop surface exist; editor/history/acceptance loop does not. |
| 1.2 capture/personal library | `partial` | Offline durable text capture and local Archive exist; media/import/search/annotation breadth remains. |
| 1.3 Apple context adapters | `missing` | Targets/seams exist without real incremental HealthKit/calendar/location adapters. |
| 1.4 Now/Tomorrow Map v1 | `partial` | Quiet Now exists; deterministic context and Tomorrow Map do not. |
| 1.5 telemetry/review | `contract-only` | Schemas exist; declared questions and product review loop do not. |
| 2.1 decision journal | `contract-only` | Decision schemas/events exist without a usable loop. |
| 2.2 consequence engine v1 | `missing` | No propagation engine or replay calibration at snapshot. |
| 2.3 intent engine v1 | `partial` | C.1 silence gate, budgets, cooldown and channel policy are tested; opportunity generation/durability/delivery are absent. |
| 2.4 AI synthesis/evaluations | `deferred` | Correctly gated until deterministic context, evidence and evaluations exist. |
| 2.5 one-month dogfood | `missing` | Requires owner use and prior Edition 2 gates. |
| 3.1 evidence library | `contract-only` | Contracts only. |
| 3.2 N-of-1 laboratory | `contract-only` | Contracts only. |
| 3.3 training/nutrition depth | `deferred` | No unsafe or unsupported guidance is enabled. |
| 3.4 archive v1 | `contract-only` | Episode/chapter contracts and raw capture list only. |
| 3.5 relationship memory | `contract-only` | Conservative person/relationship contracts only. |
| 4 meta-learning/expressive world | `deferred` | Correctly sequenced after proved lower editions. |

## Appendix E.2 closure ledger

`repo` means repository-verifiable; `owner` means evidence must be produced on
owner infrastructure/devices; `lived` means only the owner can accept the
personal state or complete the longitudinal protocol.

| Requirement | Gate | Status | Evidence or blocker |
| --- | --- | --- | --- |
| Accepted Charter, life stage and season | `lived` | `missing` | Contracts only; requires editor and explicit owner acceptance. |
| Now can intentionally show silence | `repo` | `implemented` | Quiet iPhone Now state exists; deterministic silence policy remains to connect. |
| No universal Life Score or people ranking | `repo` | `verified` | Constitution and implementation omit both. |
| Guilt-free re-entry | `repo` | `missing` | No re-entry policy/surface at snapshot. |
| Two-line proactive copy | `repo` | `missing` | No enabled proactive copy pipeline or lint. |
| Offline local capture | `repo` | `verified` | Atomic portable/native capture tests pass. |
| Two-device convergence | `repo` | `verified` | Simulated backend/native convergence and conflict tests. |
| Migration fixtures | `repo` | `partial` | Current migrations test; full historical fixture matrix absent. |
| Intelligible owner export | `repo` | `partial` | Database export exists; full multi-format signed encrypted export absent. |
| Cloud backup/PITR enabled | `owner` | `implemented` | IaC exists; no deployment evidence. |
| Clean-room restore succeeded | `owner` | `implemented` | Tool/runbook exists; no owner execution evidence. |
| No wipe-based release step | `repo` | `verified` | Migration and rollback docs explicitly forbid routine data wipes. |
| Incremental/revocable health/calendar permissions | `owner` | `missing` | Adapters not implemented. |
| Permission denial degrades gracefully | `owner` | `missing` | Adapters not implemented. |
| Cached freshness-aware widget | `owner` | `missing` | Widget target is skeletal. |
| Physical-device background proof | `owner` | `missing` | Explicitly not performed. |
| Production avoids beta-only APIs | `owner` | `partial` | Configuration targets stable SDKs; Xcode archive not performed. |
| Offline Watch quick actions | `owner` | `missing` | Watch shell only. |
| Deterministic model-free context | `repo` | `missing` | Context contract exists; assembly service absent. |
| Consequential model output structured/versioned | `repo` | `contract-only` | ModelRun and output contracts exist; no enabled model route. |
| Recommendation citations | `repo` | `missing` | No recommendation service. |
| Uncertainty/insufficiency outputs | `repo` | `contract-only` | Types exist; route behavior absent. |
| Provider fallback | `repo` | `missing` | Providers remain disabled. |
| Prompt-injection/sensitive-route tests | `repo` | `missing` | No model pipeline/eval suite. |
| Model rollback | `repo` | `missing` | No model release system. |
| Notification budget/silence gate | `repo` | `verified` | `intent/policy.py` enforces hard gates, daily/window budgets, exponential cooldown and least-intrusive delivery with focused tests. |
| Opportunity expiry/delivery recheck | `repo` | `missing` | Contracts only. |
| Standing permissions visible/revocable | `repo` | `missing` | Contracts only. |
| External action confirmation | `repo` | `missing` | Authority policy absent; no external actions enabled. |
| Synced global proactive pause | `repo` | `missing` | No domain loop. |
| Source/claim provenance inspectable | `repo` | `partial` | Provenance contracts and ledger exist; evidence UI/query absent. |
| Population/personal evidence distinct | `repo` | `contract-only` | Evidence contracts distinguish them; query behavior absent. |
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

- `make verify` most recently reported 106 backend tests, 85.65% backend
  coverage, 67 deterministic generated schema artifacts, OpenTofu validation,
  and five mocked OpenTofu plans.
- The portable Swift 6.1 release suite reported 45 tests passing.
- iOS sources passed parser-only validation and `apple/project.yml` passed YAML
  structure checks.
- No Xcode build, signing, simulator, Apple framework integration, TestFlight,
  cloud deployment, live restore, or physical-device validation is claimed.

The authoritative owner-only evidence procedure is
`docs/deployment/OWNER_HANDOFF.md`.
