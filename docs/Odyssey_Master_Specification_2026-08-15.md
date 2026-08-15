# Odyssey
## Master Research, Product Architecture & Implementation Specification

**Edition:** Architecture Commission — Edition 1  
**Research and platform cutoff:** 15 August 2026  
**Intended recipient:** An autonomous implementation agent with no prior project context  
**Primary product owner:** One person  
**Primary platforms:** iPhone, Apple Watch, iPad, and Mac  
**Source commission:** The uploaded *Odyssey: Master Research, Product Architecture & Implementation Planning Commission*.

---

## Contents

- [1. Executive summary](#1-executive-summary)
- [2. Refined North Star](#2-refined-north-star)
- [3. Odyssey Constitution](#3-odyssey-constitution)
- [4. Premise review: what the commission gets right, and what must change](#4-premise-review-what-the-commission-gets-right-and-what-must-change)
- [5. Research synthesis and design consequences](#5-research-synthesis-and-design-consequences)
- [6. Good-life model](#6-good-life-model)
- [7. Life-stage and season model](#7-life-stage-and-season-model)
- [8. Ontology and knowledge model](#8-ontology-and-knowledge-model)
- [9. Decision architecture](#9-decision-architecture)
- [10. Temporal consequence engine](#10-temporal-consequence-engine)
- [11. Intent and context-aware intervention engine](#11-intent-and-context-aware-intervention-engine)
- [12. Memory architecture](#12-memory-architecture)
- [13. Personal learning model](#13-personal-learning-model)
- [14. Scientific evidence architecture](#14-scientific-evidence-architecture)
- [15. Score philosophy and specification](#15-score-philosophy-and-specification)
- [16. AI philosophy](#16-ai-philosophy)
- [17. Trust and agency model](#17-trust-and-agency-model)
- [18. Experience architecture](#18-experience-architecture)
- [19. Visual and art direction](#19-visual-and-art-direction)
- [20. Apple ecosystem architecture](#20-apple-ecosystem-architecture)
- [21. Integration strategy](#21-integration-strategy)
- [22. Data architecture](#22-data-architecture)
- [23. Backend architecture](#23-backend-architecture)
- [24. AI and model architecture](#24-ai-and-model-architecture)
- [25. Offline and synchronization strategy](#25-offline-and-synchronization-strategy)
- [26. Notification and background strategy](#26-notification-and-background-strategy)
- [27. Observability](#27-observability)
- [28. Product telemetry and self-improvement](#28-product-telemetry-and-self-improvement)
- [29. Evaluation framework](#29-evaluation-framework)
- [30. Security model](#30-security-model)
- [31. Data durability, schema evolution, and migrations](#31-data-durability-schema-evolution-and-migrations)
- [32. Failure modes and pre-mortem](#32-failure-modes-and-pre-mortem)
- [33. Technology choices and alternatives considered](#33-technology-choices-and-alternatives-considered)
- [34. Repository architecture](#34-repository-architecture)
- [35. Testing strategy](#35-testing-strategy)
- [36. Deployment architecture](#36-deployment-architecture)
- [37. Development-environment recommendation](#37-development-environment-recommendation)
- [38. Detailed implementation roadmap](#38-detailed-implementation-roadmap)
- [39. Dependency graph between major systems](#39-dependency-graph-between-major-systems)
- [40. What should be built first and why](#40-what-should-be-built-first-and-why)
- [41. What should deliberately be deferred and why](#41-what-should-deliberately-be-deferred-and-why)
- [42. Explicit open questions](#42-explicit-open-questions)
- [43. Experiments requiring real-world usage](#43-experiments-requiring-real-world-usage)
- [44. One-week evaluation protocol](#44-one-week-evaluation-protocol)
- [45. One-month evaluation protocol](#45-one-month-evaluation-protocol)
- [46. Instructions for the next major development iteration](#46-instructions-for-the-next-major-development-iteration)
- [47. Comprehensive implementation-agent handoff](#47-comprehensive-implementation-agent-handoff)
- [48. Scenario stress tests](#48-scenario-stress-tests)
- [Appendix A. Core domain contracts](#appendix-a-core-domain-contracts)
- [Appendix B. API and event contracts](#appendix-b-api-and-event-contracts)
- [Appendix C. Reference policy algorithms](#appendix-c-reference-policy-algorithms)
- [Appendix D. Research and official-source register](#appendix-d-research-and-official-source-register)
- [Appendix E. Requirements traceability and final definition of done](#appendix-e-requirements-traceability-and-final-definition-of-done)

## How to read this specification

This is not a conventional PRD. It is a product constitution, evidence synthesis, domain model, systems architecture, interaction specification, implementation plan, and evaluation contract.

The following labels have normative meaning:

- **[INVARIANT]** — an implementation must not change this without a deliberate architecture decision recorded in an ADR and approved by the product owner.
- **[STRONG RECOMMENDATION]** — the researched default. Departures are permitted only with a written rationale and replacement evaluation plan.
- **[OPEN DESIGN SPACE]** — the implementation agent should choose after a bounded spike, prototype, or benchmark.
- **[EXPERIMENT]** — cannot be settled by reasoning alone; implement behind a flag and evaluate through real use.
- **[USER PREFERENCE]** — comes from the commission rather than scientific evidence.
- **[EVIDENCE-BACKED]** — directly supported by research or official platform documentation cited in the source register.
- **[ENGINEERING JUDGMENT]** — a reasoned architecture choice rather than an empirical fact.
- **[PRODUCT HYPOTHESIS]** — plausible, but must earn permanence through use.
- **[AESTHETIC CHOICE]** — intended to embody the product philosophy; it is not presented as science.

When these labels conflict, the order of authority is:

1. safety, data integrity, and platform constraints;
2. explicit user choices made after this specification;
3. invariants;
4. strong recommendations;
5. experiments and open design spaces.

---

# 1. Executive summary

Odyssey should be built as a **personal navigation system for living deliberately**, not as a universal productivity app, not as a quantified-self dashboard, and not as an autonomous agent that attempts to run a life.

Its job is to maintain a versioned account of what matters in the current season, assemble relevant personal and scientific evidence, make consequential choices easier to see, reduce the friction of actions already judged worthwhile, and preserve an auditable record of how a life changes over decades.

The commission proposes a “decision OS.” That is directionally useful but ontologically incomplete. Many of the most valuable parts of life are not decisions: being absorbed in a conversation, grieving, falling in love, exploring a city, recovering from illness, playing, noticing, and changing one’s mind. **Decision support is therefore a central capability, not the root object of the universe.** Odyssey’s more suitable root model is:

> **A person moves through situations, lives by changing commitments, encounters choices, takes actions, has experiences, observes outcomes, and revises their understanding.**

The product is organized around six capabilities:

1. **Orientation** — What matters in this season? What is the shape of today and tomorrow?
2. **Decision support** — What is the real trade-off, what are the stakes, and what should happen next?
3. **Friction reduction** — Make the hundredth worthwhile action much easier than the first.
4. **Learning** — Distinguish population evidence, personal observation, causal hypotheses, and actual N-of-1 experiments.
5. **Memory** — Preserve raw history, provenance, semantic meaning, and narrative episodes without flooding attention.
6. **Evolution** — Learn how both the user and Odyssey are changing, then propose rather than silently impose product adaptations.

The system should be **local-first but not local-only**. The Apple clients must remain fast and useful offline. A local SQLite database is the immediate operational source for the native experience. A cloud PostgreSQL service provides durable synchronization, long-running jobs, integrations, research ingestion, AI orchestration, backup, and cross-device history. Apple Health remains canonical for standard health samples. Odyssey owns semantic entities that other systems do not: seasons, decisions, intentions, training blocks, food presets, evidence claims, relationship meaning, experiments, and chapters.

The system should not make an LLM its database, memory, scheduler, policy engine, or authority boundary. Deterministic software owns state, permissions, provenance, constraints, and side effects. Models perform bounded tasks such as synthesis, extraction, explanation, hypothesis generation, and option comparison. Every consequential model output is structured, traceable, and subject to policy gates.

The Apple architecture should target the latest public stable Apple platform at implementation time; as of this specification, **iOS 26 is the stable baseline and iOS 27 capabilities remain progressive enhancements behind availability checks**. HealthKit, WorkoutKit, EventKit, App Intents, WidgetKit, ActivityKit, BackgroundTasks, AlarmKit, Core Location, and the Foundation Models framework all have useful roles, but none should be treated as an unconstrained always-on runtime. Official Apple documentation is explicit that widget refreshes are budgeted, background processing is opportunistic and interruptible, calendar read access requires full permission, and background location must be justified. [A01–A10]

The first working edition must not attempt the entire vision. It should establish the durable substrate and prove five high-value loops:

- a versioned Season Charter;
- a context-rich “Now” surface and optional Tomorrow Map;
- fast health/nutrition/training capture with Apple Health integration;
- a small intent engine for sleep, training, career preparation, and important relationships;
- product telemetry and replayable evaluations from day one.

The first edition should deliberately defer an elaborate 3D life world, continuous GPS logging, generalized autonomous agents, broad email/finance ingestion, automated job applications, compatibility scoring for relationships, and a single totalizing life score.

Success after one month is not “daily active use.” Success is that Odyssey is repeatedly trusted at naturally occurring decision points, saves more cognitive effort than it creates, has not damaged spontaneity, and has accumulated reliable data without losing or corrupting it.

---

# 2. Refined North Star

## 2.1 North Star statement

> **Odyssey helps one person navigate a changing life deliberately. It keeps a versioned model of what matters now, turns personal history and honest evidence into timely choices, lowers the friction of acting on those choices, and preserves the journey without turning life into a performance dashboard.**

## 2.2 Product promise

Odyssey should make a good life:

- easier to **see** when priorities compete;
- easier to **choose** when immediate impulses obscure later consequences;
- easier to **live** by reducing avoidable cognitive and operational friction;
- richer to **experience** by protecting autonomy, relationships, play, and spontaneity;
- more truthful to **learn from** through provenance and calibrated uncertainty;
- extraordinary to **look back upon** through a durable, naturally generated archive.

## 2.3 What “personal operating system” means

The phrase is acceptable only if it means an intelligence and coordination layer over existing systems. It must not imply that Odyssey owns every datum or becomes the only interface to life.

Odyssey should:

- delegate commodity storage and execution to systems that already do them well;
- own semantic interpretation, cross-domain context, and the long-term personal model;
- expose its reasoning and uncertainty;
- preserve the ability to export, inspect, repair, and migrate data;
- allow the user to override, ignore, or abandon any workflow without being punished.

## 2.4 Primary product outcome

The primary outcome is **better-calibrated living**, defined as repeated alignment between:

- the user’s current, explicitly versioned understanding of a good life;
- the actual constraints and opportunities of the present situation;
- decisions and actions taken with acceptable cognitive cost;
- experienced quality, not merely measurable output;
- learning that causes future models to become more truthful.

This outcome is intentionally plural. Odyssey must not collapse flourishing into a single utility function.

---

# 3. Odyssey Constitution

These principles are durable design tests. A feature that violates several of them should normally not ship.

1. **Optimize for a good life, not visible productivity.** Completed tasks are evidence only when they serve something that matters.
2. **Model a changing person.** Values may endure, but identities, seasons, goals, capacities, and preferences are versioned—not permanent labels.
3. **Navigation precedes optimization.** The system must first understand where the user is trying to go and what must not be sacrificed.
4. **Decisions are central, not total.** Odyssey supports choices while preserving presence, play, grief, love, surprise, and experiences that should not be instrumentalized.
5. **Autonomy, competence, and relatedness are product constraints.** Guidance should increase agency and capability without weakening human connection. [R01–R02]
6. **AI reduces the cost of judgment; it does not replace judgment.** Models assemble context and prepare choices. Authority remains explicit.
7. **Context beats clock time.** Interventions are defined by opportunity, readiness, deadline, and burden—not by arbitrary recurring times.
8. **Connect now to later without moralizing.** Show plausible consequences and actual stakes; do not turn every deviation into failure.
9. **Retention is cheap; attention is precious.** Preserve useful history, but earn every interruption and every item placed on screen.
10. **Provenance is part of truth.** Every important claim must be traceable to observation, source, inference, model run, or user statement.
11. **Population evidence and personal evidence are different.** Neither automatically overrides the other; both carry applicability and uncertainty.
12. **Measurement must remain subordinate to meaning.** Scores are explanatory instruments, never definitions of worth.
13. **Personal history should reduce future friction.** Repetition should create presets, predictions, defaults, and faster capture.
14. **Reversibility governs autonomy.** The more irreversible, external, sensitive, or costly an action, the stronger the required authorization.
15. **Behavior generates hypotheses, not secret redesigns.** Odyssey may propose adaptations; it must not silently reshape priorities or workflows.
16. **Delegate commodity capabilities; own the intelligence layer.** Do not rebuild health stores, calendars, maps, or messaging without a compelling gap.
17. **Preserve spontaneity and legitimate exceptions.** A surprising, inefficient, wonderful day may be exactly right.
18. **Silence is a first-class output.** A system that knows much but interrupts rarely is more intelligent than one that constantly demonstrates awareness.
19. **The interface should teach the model.** Spatial layout, motion, hierarchy, and language must make trade-offs and time intelligible.
20. **Durability outranks novelty.** A beautiful feature is not valuable if an app reinstall, migration, expired build, or provider outage destroys the record.

---

# 4. Premise review: what the commission gets right, and what must change

## 4.1 “Decision OS” is useful but too narrow

**Commission premise:** decisions may be more fundamental than goals.

**Resolution:** decisions are more operationally useful than goals, but neither is the sole primitive.

A life includes:

- **commitments** that constrain future choices;
- **situations** that create opportunities and limits;
- **decisions** that select among meaningful options;
- **actions** that enact or fail to enact those decisions;
- **experiences** whose value may not be instrumental;
- **outcomes** that may be delayed, stochastic, or only partly caused by action;
- **interpretations** that change what prior events mean.

Odyssey should therefore be a navigation system with a decision architecture, not a database of goals or an endless queue of decisions.

## 4.2 “Store almost everything” needs admission rules

**Commission premise:** maximum memory, selective attention.

**Resolution:** retain broadly, but not indiscriminately.

There are at least five reasons not to collect a datum merely because it is technically available:

1. it has no plausible future decision or archive value;
2. acquisition imposes battery, permission, financial, or maintenance cost;
3. its meaning is too ambiguous to be safely interpreted;
4. it creates exposure disproportionate to value;
5. its existence changes behavior in a harmful or performative way.

Every integration must answer a **Data Value Test**:

- What future decision, reflection, or recovery problem could this datum improve?
- Is it available from a canonical system later, or must it be captured now?
- What is the cost of collection, normalization, and long-term schema support?
- How likely is misinterpretation?
- Can the user inspect and delete it?

“Retention is cheap” is directionally true for storage, but false for semantics, migrations, indexing, security, and attention. The architecture should retain raw data generously **after an explicit ingestion contract exists**.

## 4.3 A knowledge graph should be derived, not sovereign

**Commission premise:** a personal or temporal knowledge graph may be central.

**Resolution:** model graph-shaped relationships, but do not begin with Neo4j or a graph-only source of truth.

Most high-value operations need:

- exact temporal predicates;
- provenance joins;
- transactional updates;
- range queries;
- aggregation;
- deterministic migrations;
- conflict resolution.

These fit relational and event-oriented storage well. Semantic edges and graph neighborhoods should be materialized as derived tables or query-time views. A dedicated graph database should be introduced only if measured workloads cannot be served acceptably by PostgreSQL recursive queries and indexed edge tables.

## 4.4 Personalization can become historical imprisonment

A model trained on prior behavior can turn “what happened before” into “who you are.” Odyssey must distinguish:

- stated preference from inferred preference;
- stable trait from current state;
- recurring pattern from season-specific behavior;
- convenience prediction from normative recommendation.

Every inferred preference needs scope, confidence, evidence, last-confirmed time, and an expiry or revalidation rule. The interface must allow “not anymore” and “surprise me.”

## 4.5 Scores can motivate and still be dangerous

The user likes scores. The commission is correct that 100% should be season-relative. But even a contextual score can become oppressive if it is visible too often, reacts sharply to noisy data, or embeds hidden moral judgments.

Resolution:

- no universal Life Score;
- no streak loss as punishment;
- no scoring of people or romantic compatibility;
- no daily score without confidence and explanation;
- use capped, diminishing contributions so more is not always better;
- evaluate whether a score changes a decision, not whether it increases engagement;
- preserve a score-free mode.

## 4.6 Scientific grounding must not become false precision

Many domains relevant to Odyssey have heterogeneous evidence, small effects, publication bias, context dependence, and limited direct applicability to one person. The evidence architecture should borrow transparency concepts from GRADE—risk of bias, inconsistency, indirectness, imprecision, and publication bias—without pretending Odyssey is a clinical guideline organization. [R16]

The system must be able to say:

- “Strong population evidence, but only indirectly applicable here.”
- “A plausible mechanism with weak outcome evidence.”
- “A repeated personal correlation, not a causal result.”
- “A randomized personal experiment, but too few cycles for confidence.”
- “No adequate evidence; this is a preference-based suggestion.”

## 4.7 The voyage metaphor has a proper boundary

The voyage metaphor is powerful for orientation, seasons, chapters, and archive. It is harmful when applied to every interaction. A food logger should not require navigating a ship. A medication or injury screen should not be whimsical. A calendar permission prompt should be literal.

Use metaphor to communicate structure, not to obscure function.

## 4.8 “Deeply personalized” does not imply omnipresence

A system can know more and intervene less. The target is not maximal prediction. It is **high precision at consequential moments**. Odyssey should prefer a smaller number of trusted interventions over a large number of weakly personalized nudges.

---

# 5. Research synthesis and design consequences

This section converts research into product decisions rather than presenting a literature catalogue.

## 5.1 Flourishing is plural

No single accepted theory exhausts the good life. Useful traditions distinguish subjective wellbeing, meaning, growth, autonomy, mastery, positive relations, purpose, and environmental fit. Ryff’s eudaimonic model and Self-Determination Theory are especially useful because they resist reducing wellbeing to momentary pleasure. [R01–R03]

### Design consequence

Odyssey should maintain a plural good-life model containing:

- **felt quality:** affect, vitality, satisfaction, stress;
- **psychological needs:** autonomy, competence, relatedness;
- **direction:** meaning, purpose, identity, values;
- **capabilities:** health, skills, financial and practical agency;
- **relationships:** love, belonging, care, reciprocity, community;
- **experience:** curiosity, play, beauty, adventure, rest;
- **integrity:** acting consistently with chosen commitments;
- **stewardship:** obligations to future self, people, and resources.

These are lenses, not permanent weighted KPIs.

## 5.2 Autonomy-supportive systems are more appropriate than controlling systems

Self-Determination Theory identifies autonomy, competence, and relatedness as basic psychological needs. A 2024 meta-analysis covering 4,561 effect sizes from 881 independent samples reported strong relationships between interpersonal need support, need satisfaction, and subjective wellbeing, with smaller positive associations with performance. [R01–R02]

### Design consequence

Odyssey’s language and interaction should:

- provide meaningful rationale;
- offer constrained choices rather than commands;
- acknowledge feelings and context;
- provide structure and feedback that builds competence;
- avoid shame, threats, and “you failed” framing;
- never substitute itself for human support.

The system should not optimize compliance. It should optimize **self-endorsed action with informed agency**.

## 5.3 Relationships are not a secondary wellness metric

A large meta-analysis of 148 studies and 308,849 participants found stronger social relationships associated with substantially higher survival likelihood; the exact causal pathways and applicability vary, but the broad importance of social connection is difficult to dismiss. [R04]

### Design consequence

Relationships must be a first-class domain, while avoiding CRM language and instrumental ranking. Odyssey should represent:

- user-authored significance and relationship type;
- shared episodes and commitments;
- time since meaningful—not merely any—contact;
- care obligations and important dates;
- relationship season and desired direction;
- uncertainty and privacy sensitivity.

It should never infer a person’s worth from response frequency, calculate a “friend score,” or recommend abandoning a relationship from sparse behavioral data.

## 5.4 Intentions work better when tied to opportunities

Implementation intentions specify when, where, and how a behavior will happen. A meta-analysis of 94 independent tests found a medium-to-large effect on goal attainment, while habit research shows automaticity develops over highly variable time spans rather than a mythical fixed number of days. [R05–R06]

### Design consequence

Goals should often compile into context-linked intentions:

> When a suitable opportunity state is detected, make the next action obvious and cheap.

Examples:

- “After waking, before calories or substantial fluids, offer weight capture.”
- “When the calendar shows a 45–75 minute open window and tomorrow’s interview is within 72 hours, surface the next prepared practice set.”
- “When near the gym, readiness is acceptable, and no conflicting commitment exists, make the planned session one tap away.”

Do not pretend all habits should become daily streaks. Some desired actions are weekly, seasonal, opportunistic, or intentionally varied.

## 5.5 Just-in-time interventions require receptivity and burden models

JITAIs formalize distal outcomes, proximal outcomes, tailoring variables, decision points, intervention options, and decision rules. Micro-randomized trials provide a method for estimating proximal intervention effects over repeated decision points. [R07–R08]

### Design consequence

The intent engine must model more than “is this relevant?” It must also estimate:

- availability;
- receptivity;
- urgency;
- interruption cost;
- prior notification burden;
- confidence that the context is correct;
- expected value of silence.

A relevant message at the wrong moment is a bad intervention.

## 5.6 Personal informatics succeeds or fails as a process

Personal informatics research describes linked stages of preparation, collection, integration, reflection, and action, with barriers at each stage. More recent work also documents unintended consequences including cognitive load, emotional stress, obsessive tracking, social effects, and unhealthy behavior. [R09–R12]

### Design consequence

Odyssey must evaluate each tracking loop end to end:

- Is capture cheap enough?
- Is the datum integrated correctly?
- Does reflection produce a useful interpretation?
- Does the interpretation lead to a better decision?
- Does the entire loop remain psychologically healthy?

A dashboard that collects beautifully but never changes a decision is not successful.

## 5.7 N-of-1 evidence can be rigorous, but only in narrow conditions

N-of-1 trials adapt randomized or crossover methods to one person and are most appropriate for reversible interventions with reasonably rapid onset and offset, stable outcomes, and repeatable conditions. They are not suitable for every health or life question. [R11]

### Design consequence

Odyssey must distinguish:

1. anecdote;
2. descriptive pattern;
3. adjusted observational association;
4. causal hypothesis;
5. planned personal experiment;
6. replicated personal result.

The product must never label a correlation “what works for you.” It may say “this pattern has appeared repeatedly” and explain confounders.

## 5.8 Measurement changes behavior

Goodhart’s law and the broader literature on performance metrics warn that a measure used as a target can cease to represent the intended objective. Goal pursuit can also narrow attention, encourage unethical shortcuts, increase risk, and damage intrinsic motivation when poorly designed. [R13]

### Design consequence

Scores must be:

- multi-dimensional;
- context-conditioned;
- capped;
- explainable;
- revisable;
- quiet by default;
- evaluated for adverse behavioral effects.

Odyssey should frequently display **qualitative state bands and explanations** instead of false numerical precision.

## 5.9 Human-AI systems need expectation setting, correction, and graceful failure

The Microsoft human-AI interaction guidelines emphasize making capabilities and limits clear, timing services based on context, supporting dismissal and correction, explaining behavior, learning cautiously, and providing global controls. Research on appropriate reliance further distinguishes trust from correct reliance: a user should accept good AI advice and reject bad AI advice. [R14–R15]

### Design consequence

Every AI-assisted surface must support:

- a clear indication of what is inferred versus observed;
- confidence appropriate to the task;
- source inspection;
- fast dismissal;
- correction with durable semantics;
- a deterministic fallback;
- a record of what changed after feedback.

Trust is not maximized. It is calibrated.

## 5.10 Health recommendations require domain-specific evidence policies

Representative evidence is strong for some broad recommendations—such as sufficient adult sleep and regular physical activity—but exact prescriptions still depend on individual context. Evidence for nutrition, training, recovery, and cognitive interventions varies widely by question. [R17–R20]

### Design consequence

Odyssey should not have one generic “science confidence” field. It needs claim-level applicability, outcomes, population, intervention details, effect size, and uncertainty. Health advice with meaningful risk must be conservative, sourced, and clearly outside diagnosis or treatment unless a qualified clinician is involved.

## 5.11 Local-first architecture aligns with responsiveness and ownership

Local-first software treats the local device copy as primary for interaction and uses servers for synchronization and coordination, combining low latency and offline resilience with cloud benefits. [D01]

### Design consequence

Native capture must commit locally before network calls. Cloud unavailability must not block core workflows. The user must be able to export a complete, intelligible archive.

## 5.12 Event history is valuable, but pure event sourcing is unnecessary

Event sourcing offers auditability and the ability to reconstruct state, but it adds complexity in schema evolution, replay, side effects, and query projections. [D02]

### Design consequence

Use an append-only fact/event ledger for observations, semantic changes, decisions, and audit-critical transitions. Use ordinary relational state for operational entities and materialized projections. Do not event-source transient UI state or every cache mutation.

---
# 6. Good-life model

## 6.1 Model purpose

The good-life model is not a philosophical truth engine. It is a versioned, inspectable agreement about what deserves attention in the user’s present life.

**[INVARIANT]** The model must preserve tensions rather than resolving every conflict into one scalar score.

## 6.2 Three layers

### Layer A — Enduring charter

Relatively stable, reviewed infrequently:

- chosen values and anti-values;
- responsibilities the user considers non-negotiable;
- desired character or ways of being;
- general conception of flourishing;
- boundaries around health, relationships, work, money, and integrity;
- explicit “Odyssey must never optimize me into…” statements.

This layer changes through a deliberate `CharterRevision`, not implicit behavior.

### Layer B — Life-stage model

Changes over years or major transitions:

- career stage;
- partnership/family stage;
- health constraints and capabilities;
- geographic and financial context;
- care responsibilities;
- identity transitions;
- major horizons and irreversible commitments.

Life stage is descriptive, not prescriptive. Odyssey must not infer culturally normative milestones.

### Layer C — Season portfolio

Changes over weeks or months:

- one dominant direction;
- zero to two supporting directions;
- foundations that must be protected;
- explicit non-goals;
- constraints and opportunity budgets;
- indicators of progress;
- review date and transition criteria.

A season is not a theme label. It is a compact decision policy.

## 6.3 Good-life lenses

Each Season Charter considers the following lenses. They are not all maximized simultaneously.

| Lens | Core question | Typical evidence | Failure if over-optimized |
|---|---|---|---|
| Autonomy | Does this life feel self-endorsed? | stated choice, felt agency, constraint notes | isolation, refusal of useful structure |
| Competence | Is capability growing where it matters? | skill progress, outcomes, deliberate practice | endless self-improvement |
| Relatedness | Are important bonds receiving real care? | meaningful contact, shared experience, commitments | transactional relationships |
| Vitality | Is the body supporting the life being asked of it? | sleep, energy, training, symptoms | health perfectionism |
| Meaning | Does current effort connect to something worth doing? | charter, narrative, reflection | grandiosity, postponing joy |
| Experience | Is life being lived, noticed, and enjoyed? | episodes, novelty, play, beauty, presence | novelty chasing |
| Integrity | Are actions compatible with chosen principles? | decision records, commitments | rigidity, self-punishment |
| Stewardship | Are future self and dependants being protected? | finances, health, obligations | excessive caution |

## 6.4 Multi-objective decision policy

Odyssey should not calculate a hidden global utility score. It should use a layered policy:

1. **Hard constraints:** safety, law, explicit commitments, severe health limits, external deadlines.
2. **Protected foundations:** minimum sleep opportunity, injury constraints, essential relationships, financial limits.
3. **Seasonal priorities:** weighted, but with diminishing returns and explicit opportunity costs.
4. **Experience and spontaneity allowance:** an explicit budget for unplanned, meaningful opportunities.
5. **User judgment:** final authority when the model is incomplete or values are incommensurable.

This resembles lexicographic and satisficing decision-making more than unconstrained maximization.

## 6.5 Current initial charter seed

The implementation should ship with an editable seed based on the commission, not silently hardcode it as permanent truth.

### Dominant directions

- **Career acceleration:** exceptional current-role performance plus a high-quality external search, technical preparation, role research, applications, interviews, and learning from outcomes.
- **Finding and building an exceptional partnership:** optimize for meaningful romantic opportunity and relationship quality, not date count.

### Protected foundations

- health, energy, physical capability, attractiveness, and sustainable training;
- close friendships and family relationships;
- joy, adventure, and non-instrumental experience.

### Concrete hypotheses, not eternal goals

- meaningful progress toward a job change around October;
- sub-20-minute 5K around November;
- rotating approximately 12-week training blocks, with one discipline primary and another maintained.

Every date and target must carry `status`, `confidence`, `source`, and `review_at`.

---

# 7. Life-stage and season model

## 7.1 Season entity

A `Season` is a versioned interval during which a stable-enough decision policy applies.

Required fields:

```text
Season
- id: UUID
- title: String
- status: draft | active | winding_down | completed | abandoned
- valid_interval: [start, end?)
- dominant_direction_ids: [DirectionID]          // normally exactly one
- supporting_direction_ids: [DirectionID]        // normally 0–2
- protected_foundation_ids: [FoundationID]
- explicit_non_goals: [NonGoal]
- constraints: [Constraint]
- opportunity_budgets: [Budget]
- progress_signals: [SignalDefinition]
- failure_guardrails: [Guardrail]
- transition_triggers: [Trigger]
- review_cadence: Duration
- charter_revision_id: UUID
- created_from: user | assisted | imported
- rationale: RichText
- supersedes_season_id: UUID?
```

## 7.2 Directions, goals, projects, and commitments

These concepts must remain distinct.

- **Direction:** an enduring vector with no required finish line, such as “become an exceptional engineer” or “build a loving partnership.”
- **Goal:** a falsifiable desired outcome with a horizon, such as a 5K time.
- **Project:** a bounded body of coordinated work, such as “prepare for Company X interview.”
- **Commitment:** a promise or externally consequential obligation, such as an interview, race entry, or friend’s wedding.
- **Practice:** a repeatable behavior that develops capability or maintains a foundation.
- **Experiment:** a time-bounded protocol intended to learn, not merely achieve.

Goals should never be required for all valuable activity. A relationship, a city, or a literary interest may be represented as a direction or experience thread.

## 7.3 Season composition rules

**[STRONG RECOMMENDATION]** Enforce soft limits:

- one dominant direction;
- no more than two supporting directions;
- no more than five protected foundations;
- at least one explicit non-goal;
- at least one “what a good week feels like” qualitative statement;
- at least one transition condition beyond a date.

The UI may allow exceptions after showing the likely attention cost.

## 7.4 Season transitions

A transition is a meaningful event, not a settings edit. It should create:

- a frozen summary of the outgoing season;
- achievements and disappointments;
- decisions that changed direction;
- practices to carry forward;
- beliefs invalidated or strengthened;
- people and experiences that mattered;
- data-quality and model-quality notes;
- an explicit delta between old and new charters.

Transitions should have a quiet visual ceremony, but never force retrospective writing. Odyssey can prepare a draft from history and ask for a small number of corrections.

## 7.5 Season state machine

```text
DRAFT
  -> ACTIVE                 explicit activation
ACTIVE
  -> WINDING_DOWN           end condition approached or user decides
  -> ABANDONED              explicit cancellation with optional rationale
WINDING_DOWN
  -> COMPLETED              retrospective accepted or auto-closed after grace period
  -> ACTIVE                 extension/recommitment
COMPLETED / ABANDONED
  -> immutable, except annotations and redaction
```

No automatic season change should occur from inferred behavior alone. The system may propose one.

---

# 8. Ontology and knowledge model

## 8.1 Ontology principles

1. **Events describe what happened.**
2. **Entities provide durable identity across events.**
3. **Claims describe what Odyssey believes, with provenance and confidence.**
4. **Views summarize current state and may be recomputed.**
5. **Time is multi-dimensional.**
6. **Uncertainty is explicit.**
7. **External-system identifiers never become Odyssey’s sole durable identity.**
8. **Generated summaries are versioned interpretations, not replacement facts.**

## 8.2 Core conceptual categories

### A. Orientation

- `CharterRevision`
- `Value`
- `AntiValue`
- `IdentityStatement`
- `LifeStage`
- `Season`
- `Direction`
- `Goal`
- `Foundation`
- `Constraint`
- `NonGoal`

### B. Agency and execution

- `Commitment`
- `Project`
- `Practice`
- `Intent`
- `DecisionCase`
- `Option`
- `Recommendation`
- `Action`
- `AutomationPermission`

### C. Lived world

- `Person`
- `Relationship`
- `Place`
- `Organization`
- `Role`
- `Experience`
- `Episode`
- `Event`
- `Journey`
- `Chapter`

### D. Health and capability

- `HealthObservation`
- `HealthState`
- `TrainingBlock`
- `WorkoutPlan`
- `Workout`
- `FoodDefinition`
- `FoodOccurrence`
- `SleepEpisodeRef`
- `Capability`
- `Skill`
- `Symptom`

### E. Knowledge and learning

- `Observation`
- `Claim`
- `Hypothesis`
- `Experiment`
- `Outcome`
- `Learning`
- `EvidenceClaim`
- `EvidenceSource`
- `ApplicabilityAssessment`
- `ModelInference`

### F. Product behavior

- `SurfaceView`
- `InterventionCandidate`
- `InterventionDelivery`
- `UserFeedback`
- `WorkflowRun`
- `ProductHypothesis`
- `ProductChangeProposal`
- `EvaluationCase`
- `EvaluationRun`

## 8.3 Event, entity, claim, and projection distinction

Example: “A 7 km run occurred in Hyde Park and felt excellent.”

- Imported HealthKit workout: `ExternalObservationEvent`.
- Hyde Park: `Place` entity.
- Run: `Workout` projection referencing the external sample.
- “felt excellent”: user-reported `Observation` with its own timestamp and scale.
- “sleeping 8 hours improves long-run enjoyment”: `Hypothesis`, not fact.
- “running is part of my identity”: versioned `IdentityStatement`.
- “Spring running block is progressing”: derived `Claim` with method version.

## 8.4 Temporal semantics

Every durable fact-like record must support the relevant subset of:

- `occurred_at` — when the event happened in the world;
- `started_at`, `ended_at` — interval semantics;
- `observed_at` — when a sensor or person observed it;
- `recorded_at` — when Odyssey stored it;
- `valid_from`, `valid_to` — when a belief or relationship was considered true;
- `effective_at` — when a decision or policy takes effect;
- `superseded_at` — when a replacement interpretation became authoritative;
- `timezone_id` and original UTC offset;
- `precision` — exact, minute, hour, day, approximate interval, unknown.

**[INVARIANT]** Never infer event order from ingestion time when occurrence time exists.

## 8.5 Provenance envelope

Every imported, user-entered, inferred, or generated record must carry:

```text
Provenance
- source_kind: user | apple_health | calendar | location | integration | model | rule | import
- source_system: String
- source_record_id: String?
- source_revision: String?
- acquisition_method: permission_api | oauth | manual | share_sheet | batch_import | derivation
- captured_at: Instant
- device_id: UUID?
- model_run_id: UUID?
- rule_version: String?
- evidence_ids: [UUID]
- transform_chain: [TransformRef]
- integrity_hash: String?
```

A record without provenance may exist only as an explicitly marked legacy import.

## 8.6 Confidence and epistemic status

Do not use one floating-point confidence field for every concept. Store:

- `epistemic_status`: observed | user_asserted | inferred | predicted | hypothesized | experimentally_supported | contradicted;
- `confidence_band`: low | moderate | high;
- optional calibrated probability where a model is actually calibrated;
- `support_count`, `contradiction_count`;
- `applicability_scope`;
- `expires_at` or `review_at`;
- `method_version`.

Language shown to the user must follow the status. For example, “appears associated with” for observational data and “caused” only where the design supports causal inference.

## 8.7 Identity and relationships

### Person

A `Person` is a durable entity with minimal required data. Contact-system IDs are aliases, not primary keys.

### Relationship

A `Relationship` is an interval-valued, user-centered description of the connection between the user and another person.

```text
Relationship
- id
- person_id
- relationship_types: [friend, family, colleague, romantic, mentor, ...]
- significance: user-authored qualitative band
- desired_direction: maintain | deepen | repair | explore | release | unspecified
- current_season: free text or enum with uncertainty
- privacy_class: intimate | sensitive | ordinary
- meaningful_contact_definition
- active_interval
- notes_encrypted: Boolean
```

No reciprocal claim about the other person should be represented as fact unless directly known. “I feel close to Alex” and “Alex feels close to me” are different claims.

## 8.8 Episodes, journeys, chapters, and eras

The archive uses a hierarchy of generated or curated views:

- **Moment:** a single notable observation or event.
- **Episode:** a coherent cluster over hours or days.
- **Journey:** a bounded arc such as a trip, interview process, training block, or relationship beginning.
- **Season:** the active decision-policy interval.
- **Chapter:** a narrative interval spanning one or more seasons.
- **Era:** a major life-stage interval.

These are projections over source events. Deleting a generated summary must not delete source data. Regeneration must preserve prior versions for audit.

## 8.9 Knowledge graph position

Use a relational `semantic_edges` table:

```text
semantic_edges(
  edge_id,
  subject_type,
  subject_id,
  predicate,
  object_type,
  object_id,
  valid_range,
  confidence_band,
  provenance_id,
  created_at,
  superseded_by
)
```

Graph navigation is supported through indexed edges and recursive SQL. Embeddings support semantic recall. A dedicated graph database is deferred until a benchmark proves a need.

---

# 9. Decision architecture

## 9.1 Decision lifecycle

The improved lifecycle is:

```text
situation detected
  -> silence gate
  -> decision case opened or linked
  -> context assembled
  -> constraints and values identified
  -> options generated or imported
  -> consequences estimated by horizon
  -> uncertainty and missing information assessed
  -> recommendation policy applied
  -> user chooses / defers / delegates / rejects framing
  -> action prepared or executed under authority policy
  -> outcome window monitored
  -> learning recorded
  -> case closed, reopened, or archived
```

The silence gate precedes decision creation because not every detectable trade-off deserves product attention.

## 9.2 DecisionCase schema

```text
DecisionCase
- id
- title
- status: latent | surfaced | deliberating | decided | acting | monitoring | closed | abandoned
- trigger_refs: [EventRef]
- decision_class: immediate | scheduling | commitment | strategic | relational | health | purchase | other
- stakes: negligible | low | medium | high | critical
- urgency
- deadline
- reversibility
- externality
- sensitivity
- domains
- value_tensions
- constraints
- missing_information
- options
- recommendation_id
- user_choice
- rationale_user
- rationale_system
- confidence
- action_ids
- outcome_plan
- follow_up_at
- season_id
- created_at / closed_at
```

## 9.3 Decision importance model

Importance is not urgency. Compute an explainable band from:

- consequence magnitude;
- probability of material consequence;
- irreversibility;
- effect on protected foundations;
- external impact on other people;
- option expiry;
- alignment with dominant direction;
- uncertainty and value conflict.

The model should produce a band and reasons, not a spurious 87.3.

## 9.4 Option model

Every option may include:

- direct action;
- “do nothing”;
- delay with information-gathering plan;
- reversible trial;
- delegate;
- reframe or reject the decision.

Odyssey must not generate false symmetry. If one option violates a hard constraint, mark it rather than ranking it normally.

## 9.5 Recommendation policy

A recommendation should be issued only when:

1. the user’s relevant preferences or charter are sufficiently clear;
2. the options and material constraints are represented;
3. evidence is adequate for the strength of language used;
4. remaining uncertainty is visible;
5. the recommendation is useful now;
6. the system can articulate why it might be wrong.

Otherwise, Odyssey should ask one targeted question, present a trade-off without a recommendation, or remain silent.

## 9.6 Recommendation object

```text
Recommendation
- id
- decision_case_id
- proposed_option_id
- summary_line
- action_line
- rationale_factors: [FactorContribution]
- evidence_bundle_id
- personal_evidence_refs
- counterarguments
- confidence_band
- expiry_at
- model_run_id
- policy_version
- user_feedback
```

## 9.7 Interaction contract

Default visible form:

> **One line of stakes or trade-off.**  
> **One line with the suggested next action.**

Expandable layers:

1. immediate explanation;
2. personal context and assumptions;
3. consequence timeline;
4. scientific evidence;
5. model trace summary and uncertainty.

## 9.8 Emotional state

Odyssey may accept explicit self-reported emotion and may infer broad interaction state such as “busy” or “recently interrupted.” It must not silently diagnose mood, depression, relationship state, or intent from passive data.

When a decision is emotionally loaded, the system should distinguish:

- information needed now;
- action that can be safely delayed;
- irreversible action requiring a cooling-off period;
- the possibility that the user wants support, not optimization.

## 9.9 Decision replay

Every material case should be replayable:

- what Odyssey knew at the time;
- what it inferred;
- evidence versions used;
- options shown;
- what the user chose;
- later outcomes;
- whether the recommendation would change under the current model.

Replay is essential for evaluation and intellectual honesty.

---

# 10. Temporal consequence engine

## 10.1 Purpose

The engine connects a present action to plausible near-, medium-, and long-term consequences without pretending to predict a life.

It answers:

- What could this choice affect?
- At what horizon?
- Through which dependency path?
- How large might the effect be?
- How confident are we?
- Is the consequence recoverable?
- Does it matter in this season?

## 10.2 Architecture

The engine combines four layers:

1. **Deterministic state:** calendar, deadlines, training plan, recent sleep opportunity, travel, explicit commitments.
2. **Domain rules:** versioned, evidence-linked rules such as recovery windows or caffeine timing bounds.
3. **Personal models:** conservative associations and experiment results.
4. **Narrative synthesis:** an LLM converts structured consequence paths into concise language; it does not invent paths.

## 10.3 Dependency graph

Represent dependencies as versioned typed edges:

```text
DependencyRule
- source_state_type
- target_state_type
- direction: positive | negative | non_monotonic | unknown
- lag_distribution
- duration_distribution
- effect_model
- applicability_conditions
- evidence_claim_ids
- personal_modifier_id?
- confidence_band
- method_version
```

Examples:

- sleep opportunity -> next-day alertness;
- repeated late bedtime -> circadian irregularity;
- alertness -> interview practice quality;
- heavy lower-body session -> short-term running freshness;
- social event -> bedtime feasibility;
- travel timezone change -> sleep timing uncertainty;
- job application deadline -> option value of preparation time.

## 10.4 Horizon buckets

- **Immediate:** minutes to hours.
- **Tomorrow:** next waking period.
- **Near:** 2–7 days.
- **Block:** current training/project block.
- **Season:** weeks to months.
- **Long-term:** only for well-supported directional consequences; avoid numerical forecasts.

## 10.5 Stakes calculation

For each path:

```text
path_stake =
  consequence_magnitude_band
  × applicability
  × probability_band
  × seasonal_relevance
  × irreversibility_modifier
  × accumulation_modifier
```

These factors are stored and explained; they need not be multiplied as exact floating-point values in the user interface.

## 10.6 Accumulation and recovery

The engine must distinguish:

- isolated deviation;
- repeated deviation;
- threshold crossing;
- recoverable delay;
- compounding debt;
- planned exception.

Example output:

> **Medium stakes tonight.** Tomorrow is flexible, but this would be the third late night and Tuesday’s intervals are likely to feel worse.  
> **Suggestion:** stop at midnight, or explicitly trade Tuesday’s session for recovery.

The second option protects agency and makes the trade-off honest.

## 10.7 No moralized debt

Terms such as “sleep debt” can be useful but must not become moral balances. The engine should communicate physiological or schedule consequences, not guilt.

## 10.8 Calibration

Every consequence model must be evaluated against:

- predicted direction;
- predicted band;
- actual observed outcome where measurable;
- user-rated usefulness;
- false-alarm rate;
- whether the intervention changed behavior;
- whether the behavior change improved the intended outcome.

Calibration reports should be domain-specific. A correct calendar consequence does not validate a health prediction model.

---

# 11. Intent and context-aware intervention engine

## 11.1 Intent is the core scheduling primitive

A notification is only one delivery mechanism. The durable object is an `Intent`.

```text
Intent
- id
- desired_behavior
- proximal_outcome
- distal_direction_id
- opportunity_definition
- prerequisites
- exclusion_conditions
- acceptable_window
- deadline
- importance
- urgency_curve
- interruption_cost
- fallback_options
- delivery_surfaces
- authority_level
- cooldown
- max_frequency
- evaluation_plan
- status
```

## 11.2 Context state

The engine consumes a compact, timestamped `ContextSnapshot`:

- current time and timezone;
- location category, not necessarily raw coordinates;
- calendar occupancy and transition time;
- Focus mode exposed to the app;
- recent activity and workout state;
- sleep window and recent sleep observations;
- current season and active commitments;
- device and surface availability;
- notification burden in prior windows;
- explicit do-not-disturb and social contexts;
- confidence/freshness of each input.

## 11.3 Candidate pipeline

```text
intent due or context changed
  -> generate opportunity candidates
  -> check data freshness
  -> apply hard exclusions
  -> estimate receptivity
  -> estimate expected benefit
  -> estimate interruption + habituation cost
  -> compare with silence
  -> choose surface and timing
  -> deliver, defer, convert to ambient surface, or suppress
  -> record outcome
```

## 11.4 Silence gate

A candidate is suppressed when any of the following is true:

- context confidence is below threshold;
- action is no longer feasible;
- the user has already acted;
- a more important intervention was recently delivered;
- current interruption cost exceeds expected value;
- the intervention has been repeatedly ignored without new information;
- the user is in a protected context;
- the suggestion is obvious and already visible ambiently;
- no safe or useful action can be suggested.

Silence events should be sampled for offline audit, not logged at unlimited volume.

## 11.5 Notification budget

Initial defaults, adjustable after use:

- no more than two proactive interruptive nudges on an ordinary day;
- no more than one low-stakes nudge in any three-hour window;
- high-stakes commitments may bypass ordinary limits but still require deduplication;
- ignored low-stakes intents enter exponential cooldown;
- no streak-rescue notifications;
- no notification whose only purpose is opening the app.

These are product hypotheses, not universal truths.

## 11.6 Surface selection

| Context | Preferred surface |
|---|---|
| useful but non-urgent | widget / Smart Stack relevance |
| immediate, glanceable, low interaction | Watch complication or Smart Stack |
| bounded ongoing activity | Live Activity |
| action available in current app session | in-app decision card |
| user-requested exact alarm | AlarmKit |
| contextual but time-tolerant | local notification |
| server-derived change | APNs alert or background update, with local fallback where possible |
| deep weekly synthesis | iPhone/Mac review surface, never a long notification |

## 11.7 Learning intervention timing

Odyssey may learn timing preferences only within safe bounds:

- use contextual bandits or micro-randomization only for low-risk, reversible delivery choices;
- never randomize high-stakes medical, legal, financial, or relationship actions;
- establish a notification-free control condition;
- optimize for user-rated helpfulness and downstream action, not click-through;
- bound exploration and expose it in an experiment register.

## 11.8 Exactness constraints on Apple platforms

**[INVARIANT]** Product copy and tests must not promise exact background computation or widget refresh timing.

- WidgetKit refreshes are budgeted and coalesced; frequently viewed widgets may receive roughly 40–70 reloads per day, and timeline entries should be spaced about five minutes or more. [A03]
- `BGProcessingTask` is interruptible and runs when the device is idle; it is not a precise scheduler. [A07]
- Background pushes and APNs delivery are not guaranteed exact timers.
- AlarmKit may override Focus and silent mode, but only for explicit, user-authorized alarm semantics. [A08]

The engine must compute future candidates in advance where possible and gracefully reconcile after missed execution.

---

# 12. Memory architecture

## 12.1 Memory policy

> Store broadly under explicit ingestion contracts. Retrieve narrowly through a plan. Preserve the chain from source to interpretation.

## 12.2 Memory layers

### M0 — External canonical stores

Apple Health, Calendar, Photos, Contacts, and authorized third-party systems remain canonical where appropriate.

Odyssey stores:

- durable aliases and source identifiers;
- sync cursors and revisions;
- selected local mirrors for offline use;
- semantic annotations and cross-domain links;
- derived state with method version.

### M1 — Immutable raw observations

Examples:

- imported HealthKit sample metadata;
- OAuth payload snapshots where terms permit;
- user capture events;
- location visit observations;
- calendar change events;
- notification interaction events.

Raw payloads are append-only and content-addressed where practical.

### M2 — Normalized events

Provider-neutral events such as:

- `WorkoutCompleted`;
- `SleepEpisodeObserved`;
- `MeaningfulContactRecorded`;
- `InterviewScheduled`;
- `FoodConsumed`;
- `PlaceVisited`.

### M3 — Semantic entities and claims

People, relationships, places, projects, seasons, decisions, food definitions, evidence claims, hypotheses.

### M4 — Derived features and current state

Examples:

- seven-day sleep regularity estimate;
- current training load band;
- days until interview;
- open application stages;
- time since meaningful contact;
- notification burden;
- current “shape of tomorrow.”

Every feature includes `computed_at`, input watermark, method version, and freshness.

### M5 — Episodic memory

Generated event clusters and summaries:

- day episodes;
- trips;
- interview journeys;
- training blocks;
- relationship arcs;
- season retrospectives.

### M6 — Long-term personal model

Explicit and inferred preferences, stable-enough tendencies, experiment results, constraints, and calibration data.

### M7 — Scientific knowledge

Sources, evidence claims, applicability assessments, recommendation rules, and update history.

### M8 — Product memory

Usage telemetry, product hypotheses, workflow friction, intervention outcomes, evaluation results, and approved changes.

## 12.3 Retrieval architecture

Do not send “all memories” to a model. Use a query plan:

1. **Classify task and authority level.**
2. **Resolve temporal scope.**
3. **Run structured queries** for exact facts, commitments, and state.
4. **Expand typed relationships** through `semantic_edges` where useful.
5. **Run semantic retrieval** over eligible text and episodes.
6. **Apply recency, significance, season, and provenance filters.**
7. **Rerank** using task-specific features.
8. **Assemble a bounded evidence pack** with citations.
9. **Generate or reason.**
10. **Verify that output claims are supported by the pack.**

## 12.4 Retrieval plan object

```text
RetrievalPlan
- task_type
- temporal_window
- entity_filters
- required_fact_types
- graph_hops
- semantic_queries
- privacy_ceiling
- source_priority
- max_items
- freshness_requirements
- contradiction_policy
- output_citation_requirement
```

## 12.5 Memory admission

Generated claims enter long-term memory only when:

- the user explicitly confirms them;
- a deterministic transformation produces them;
- a validated experiment supports them;
- repeated evidence crosses a domain-specific threshold and the claim remains clearly marked inferred.

A model’s eloquent summary is not sufficient for memory admission.

## 12.6 Contradiction handling

When sources conflict:

- preserve both records;
- identify source, time, and scope differences;
- do not overwrite silently;
- prefer direct user correction for identity and preference;
- prefer canonical external systems for their owned data;
- create a `ConflictCase` if the conflict changes a consequential decision.

## 12.7 Condensation and archival summaries

Condensation creates additional views, never deletes the underlying event stream solely because a summary exists. Summaries include:

- covered event IDs or query watermark;
- prompt/model/method version;
- confidence and unresolved conflicts;
- user edits;
- regeneration lineage.

## 12.8 Forgetting and redaction

The system needs deliberate forgetting despite broad retention:

- hard deletion for user-requested sensitive content;
- tombstones propagated across devices and backups according to retention policy;
- cryptographic erasure for separately encrypted sensitive blobs where feasible;
- “exclude from AI” without deleting source data;
- “exclude from archive” for episodes that should remain operational only;
- expiry for weak inferred preferences.

## 12.9 Audit question

Every user-visible factual statement should be able to answer:

> “Why does Odyssey believe this, as of when, and from which source?”

---

# 13. Personal learning model

## 13.1 Learning categories

| Category | Example | Default authority |
|---|---|---|
| Explicit preference | “I prefer evening dates to weekday lunches.” | high within stated scope |
| Explicit value | “Close friendships are a protected foundation.” | charter-level |
| Observation | “I slept 6h 20m before this run.” | factual if source is reliable |
| Descriptive pattern | “Better run ratings often follow longer sleep.” | low–moderate |
| Causal hypothesis | “More sleep improves interval quality.” | hypothesis only |
| Personal experiment result | randomized caffeine cutoff experiment | moderate if well designed |
| Stable trait inference | “User is introverted.” | discouraged; high bar |
| Temporary state | “Likely overloaded this week.” | expires quickly |
| Seasonal preference | “Four runs per week during running block.” | active season only |

## 13.2 Trait restraint

**[INVARIANT]** Odyssey should prefer stateful and contextual explanations over fixed personality labels.

A trait-like claim requires:

- evidence across multiple contexts and seasons;
- explicit user review;
- a clear purpose;
- expiry/revalidation;
- an easy “not anymore” control.

## 13.3 Personal association model

For observational relationships:

- use pre-specified features where possible;
- include obvious confounders;
- report sample size and missingness;
- avoid testing hundreds of variables without multiple-testing correction;
- use shrinkage or Bayesian priors to avoid extreme small-sample estimates;
- report effect distributions or bands, not only point estimates;
- require temporal precedence;
- separate within-person from between-season effects;
- detect change points before pooling across the entire history.

## 13.4 N-of-1 experiment framework

A personal experiment record contains:

```text
Experiment
- question
- rationale
- intervention
- comparator
- primary_outcome
- secondary_outcomes
- inclusion_conditions
- exclusion_conditions
- design: AB | BA | ABAB | randomized_crossover | micro_randomized | observational
- randomization_seed
- period_length
- washout
- minimum_cycles
- stop_rules
- adverse_event_plan
- analysis_plan
- preregistered_at
- status
- result
- interpretation
- replication_status
```

### Appropriate experiment examples

- caffeine cutoff time and sleep onset;
- preparation session timing and completion/quality;
- notification delivery surface;
- meal preset design and logging completion;
- training warm-up variants with low injury risk.

### Inappropriate without clinical oversight

- medication changes;
- dangerous sleep restriction;
- extreme diets;
- injury-loading experiments;
- experiments involving other people without their awareness;
- manipulative romantic or social strategies.

## 13.5 Preference drift

Use time-decayed evidence only for convenience predictions, not values. When an old and new pattern conflict, ask:

> “This used to be common, but the last six weeks look different. Has your preference changed, or is this seasonal?”

## 13.6 User surprise budget

Odyssey should periodically surface one low-risk option outside the learned pattern when:

- the user has opted into exploration;
- the current context permits it;
- the system can explain why it is novel;
- declining does not damage a score.

This protects against preference ossification.

---

# 14. Scientific evidence architecture

## 14.1 Evidence principles

1. Recommendations and evidence claims are separate objects.
2. Evidence strength is outcome- and population-specific.
3. Source prestige does not replace methodological appraisal.
4. Applicability to the user is explicit.
5. Personal evidence is not silently merged with population evidence.
6. Every evidence-backed recommendation has an inspectable citation path.
7. Absence of evidence is not evidence of no effect.
8. Fast-changing technical guidance and stable scientific guidance use different refresh policies.

## 14.2 EvidenceSource

```text
EvidenceSource
- id
- title
- authors
- publication
- year
- doi / url / identifier
- source_type: guideline | systematic_review | meta_analysis | RCT | cohort | mechanistic | expert_consensus | official_docs | other
- domain
- population
- interventions
- comparators
- outcomes
- publication_status
- retraction_status
- retrieved_at
- full_text_location
- license
- ingestion_method
- checksum
```

## 14.3 EvidenceClaim

```text
EvidenceClaim
- id
- proposition
- direction
- effect_size
- uncertainty_interval
- outcome
- time_horizon
- source_ids
- certainty_band: very_low | low | moderate | high
- certainty_reasons
- applicability_tags
- contradictions
- last_reviewed_at
- reviewer: human | assisted
- status: draft | approved | deprecated | contradicted
```

## 14.4 Certainty assessment

Adapt, do not mechanically copy, GRADE concepts. Review:

- risk of bias;
- consistency across studies;
- directness to the actual question;
- precision;
- publication or dissemination bias;
- dose-response or large effect where relevant;
- recency for technical or rapidly evolving claims;
- population and setting applicability.

The UI should display a simple band, with the detailed reasons expandable.

## 14.5 Evidence classes in recommendations

A recommendation may combine:

- **Population evidence** — what tends to happen in studied populations.
- **Mechanistic support** — why an effect is biologically or psychologically plausible.
- **Expert or guideline consensus** — useful where trials are infeasible or synthesis matters.
- **Personal observation** — a pattern in this user’s data.
- **Personal experiment** — a planned within-person comparison.
- **Preference/constraint** — not scientific, but often decisive.

The rendered explanation should keep these strands separate.

## 14.6 Evidence pack

```text
EvidencePack
- decision_case_id
- claim_ids
- personal_observation_ids
- experiment_result_ids
- applicability_assessments
- uncertainty_summary
- citation_snippets
- generated_at
- knowledge_base_version
```

## 14.7 Research ingestion workflow

1. Create a question in PICO-like or domain-appropriate form.
2. Search primary databases and official sources.
3. Deduplicate and classify sources.
4. Prefer systematic reviews and authoritative guidelines where suitable.
5. Extract claims into structured fields.
6. Assess certainty and applicability.
7. Human-review consequential health claims.
8. Publish an evidence bundle version.
9. Monitor for retractions, major updates, and staleness.

Do not allow a general web-search snippet to become an approved evidence claim without source inspection.

## 14.8 Progressive disclosure

Default:

> “Sleep matters more than usual tonight.”

First expansion:

- your recent pattern;
- tomorrow and the next two days;
- confidence and assumptions.

Second expansion:

- population evidence summary;
- personal evidence summary;
- citations;
- what would change the recommendation.

## 14.9 Domain policy examples

### Sleep

Broad claims about adequate sleep and regularity can carry stronger evidence. Exact personal bedtime optimization remains a hypothesis until supported.

### Resistance and endurance training

Use established programming principles, but treat individual load-response prediction conservatively. Injury-related guidance should escalate to professional care rather than optimize through pain.

### Relationships

Evidence can inform communication or social connection, but should never be used to assign compatibility scores or manipulate another person.

### Career

Many claims will be expert practice, user outcomes, and local experiment rather than strong causal science. Label them honestly.

---

# 15. Score philosophy and specification

## 15.1 Decision

Odyssey will support scores, but it will not ship a universal, always-visible Life Score.

## 15.2 Score families

### A. State estimates

Examples: readiness, recovery confidence, schedule pressure.

- based on current observations;
- displayed as bands first;
- include freshness and confidence;
- never claim diagnosis.

### B. Alignment score

Retrospective estimate of how well a day or week matched the agreed Season Charter.

### C. Momentum

A trend over several weeks in selected directions, not a daily moral judgment.

### D. Data quality

Completeness and freshness of inputs, visible to prevent false certainty.

### E. System trust/calibration

How often Odyssey’s interventions were helpful, mistimed, wrong, or unnecessary.

## 15.3 Day Alignment

**[EXPERIMENT]** Implement behind a feature flag.

A day can have an alignment score from 0–100 only if a `DayShape` or inferred plan exists. The score answers:

> “Given what this day was for, how well did it protect what mattered?”

It does not answer:

> “How good or worthy was this day?”

Initial components:

- `core_move` — progress on the day’s primary meaningful move;
- `foundations` — whether agreed minimum health/recovery constraints were protected;
- `relationships_experience` — meaningful connection, presence, play, or planned experience;
- `integrity` — keeping or deliberately renegotiating commitments;
- `context_fit` — whether the plan appropriately adapted to illness, travel, recovery, or surprise.

Weights come from the day shape and active season. Contributions are capped. Extra work beyond the cap does not increase the score.

## 15.4 Legitimate exception handling

The user may mark:

- “Worth it”;
- “Plans changed for a better reason”;
- “Recovery day”;
- “Unexpected care obligation”;
- “Bad data”;
- “I reject this framing.”

These are not score hacks. They are model corrections and should be audited for recurrent design problems.

## 15.5 Score safety rules

- no streaks with loss aversion;
- no red failure animation;
- no social comparison;
- no score for a person or relationship;
- no health score from a single noisy measurement;
- no recommendation whose rationale is “to improve your score”;
- no hidden weight changes;
- display uncertainty;
- allow complete disabling;
- run a monthly adverse-effects check.

## 15.6 Momentum

Momentum is a smoothed view of actions and outcomes relevant to a direction. It should distinguish:

- **effort momentum** — repeated useful action;
- **capability momentum** — evidence of improved skill/capacity;
- **outcome momentum** — external results;
- **friction trend** — whether the system is becoming easier to use.

This prevents outcome luck from erasing good process and prevents busy effort from masquerading as progress.

---

# 16. AI philosophy

## 16.1 Role of AI

AI is a bounded reasoning and interface component. It may:

- extract structured facts from user-authorized text;
- summarize current context;
- propose options and missing questions;
- explain deterministic consequence paths;
- retrieve and synthesize evidence;
- cluster events into episodes;
- generate hypotheses;
- draft actions for approval;
- identify telemetry-based product hypotheses;
- prepare season retrospectives.

AI must not:

- be the only store of durable state;
- invent calendar, health, or relationship facts;
- silently write high-authority memories;
- bypass policy gates;
- send messages, applications, purchases, or calendar changes without the required authorization;
- diagnose or present weak associations as causal truth;
- make the interface depend on open-ended chat.

## 16.2 Layered intelligence

1. **Deterministic local logic** — permissions, validation, capture, projections, scheduling windows, feature computation.
2. **Cached derived state** — day shape, season state, context snapshots, evidence packs.
3. **On-device model** — low-risk extraction, classification, rewriting, and private offline assistance where availability and quality suffice.
4. **Cloud model** — complex synthesis, long-context reasoning, research, and high-quality generation.
5. **Human judgment** — all meaningful commitments and contested values.

## 16.3 “Invisible until useful” interaction rule

Do not place a chat bubble on every screen. AI should appear as:

- a concise rationale;
- a prepared option;
- a highlighted conflict;
- a suggested correction;
- an evidence disclosure;
- an optional conversational drill-down.

## 16.4 Structured outputs

All model calls that affect state must return a schema-validated object. Free text may be included as a display field, but IDs, claims, actions, confidence, and citations are structured.

Invalid outputs are rejected, retried within budget, or routed to a deterministic fallback.

## 16.5 Model portability

Provider abstraction should exist at the capability boundary, not force all models into the lowest common denominator.

```text
ModelCapabilityProfile
- structured_output
- tool_calling
- multimodal_input
- max_context
- streaming
- latency_class
- cost_class
- data_residency
- retention_policy
- local_or_cloud
- eval_status_by_task
```

Routes are selected by task policy and evaluation results, not brand preference.

## 16.6 Agent stance

**[STRONG RECOMMENDATION]** Do not start with a society of agents.

Use:

- a deterministic workflow orchestrator;
- one model call or bounded model loop per task;
- explicit tools;
- typed state;
- maximum step counts;
- cost and time budgets;
- resumable jobs;
- human checkpoints.

A higher-level agent SDK may be useful for bounded research or multi-step artifact generation. The core decision and intervention engines should own their loops directly. Current official OpenAI guidance similarly distinguishes direct Responses API use when the application wants to own loop/tool/state handling from an Agents SDK when the runtime should manage coordinated steps. [M01–M02]

## 16.7 On-device Foundation Models

Apple’s Foundation Models framework supports on-device generation, structured output, and tool calling on supported Apple Intelligence devices; current and beta capabilities differ by OS. [A09]

Use it for:

- local capture classification;
- rewriting notes;
- entity extraction;
- short summaries;
- offline natural-language queries over a small local evidence pack.

Do not assume every device supports it. Always provide deterministic or cloud fallback, and keep iOS 27-only capabilities behind availability checks until generally available and validated.

---

# 17. Trust and agency model

## 17.1 Authority dimensions

Authorization depends on:

- reversibility;
- external consequences;
- sensitivity;
- confidence;
- cost of error;
- urgency;
- user standing permission;
- whether another person is affected.

## 17.2 Authority levels

| Level | Meaning | Examples |
|---|---|---|
| L0 Observe | Store/import facts under permission | read HealthKit, import calendar |
| L1 Inform | Surface facts and state | “Interview is in 48 hours” |
| L2 Recommend | Suggest an action | “Move intervals to Tuesday” |
| L3 Prepare | Draft or stage an action | draft message, prepare calendar edit |
| L4 Execute reversible | Perform low-risk action under standing permission | create local note, mark intent complete |
| L5 Commit external | Irreversible or externally consequential action | send message, submit application, purchase |

L5 requires explicit, contemporaneous confirmation unless a narrowly scoped standing permission is intentionally created. Some action classes should never support standing permission.

## 17.3 Risk matrix

```text
required_authority = f(
  reversibility,
  externality,
  sensitivity,
  monetary_or_social_cost,
  confidence,
  scope_of_permission
)
```

Examples:

- Adjust a local recommendation: L2.
- Draft an email: L3.
- Add a tentative private calendar block to an Odyssey calendar under standing permission: L4.
- Move an accepted meeting with another person: L5.
- Submit a job application: L5 every time.
- Delete raw history: L5 plus recovery window.

## 17.4 Standing permissions

Standing permissions must be:

- action-class specific;
- resource scoped;
- time bounded;
- revocable in one place;
- logged;
- periodically reviewed;
- disabled after anomalous behavior or material model change.

Example:

> “Odyssey may create private, tentative preparation blocks in the ‘Odyssey’ calendar, never move events, maximum 90 minutes per day, for this season.”

## 17.5 Confirmation design

Avoid generic “Are you sure?” dialogs. Show:

- exact action;
- external recipient/resource;
- material consequence;
- what cannot be undone;
- why Odyssey recommends it;
- editable preview;
- authorization duration.

## 17.6 Global controls

One Trust Center must expose:

- connected data sources;
- current standing permissions;
- model providers and data routes;
- memories excluded from AI;
- recent autonomous actions;
- recommendation correction history;
- notification budgets;
- data export and deletion;
- emergency “local-only / no proactive interventions” mode.

---
# 18. Experience architecture

## 18.1 The conceptual experience

Opening Odyssey should mean neither “show me my metrics” nor “give me tasks.” It should mean:

> **Help me regain orientation with the least possible ceremony.**

The system should answer four questions, in this order:

1. **Where am I?** — current situation, energy, constraints, commitments, and season;
2. **What matters now?** — the one or two live threads whose timing or consequences make them relevant;
3. **What is available?** — useful choices, not an exhaustive agenda;
4. **What can be ignored?** — explicit permission to stop monitoring everything else.

This ordering matters. It makes the product a navigation instrument rather than a dashboard.

## 18.2 Primary spaces

The information architecture should use plain-language destinations with optional metaphor in art and motion. Do not force users to decode fantasy nouns before accessing basic functions.

### Now

The primary iPhone surface. It is a small, adaptive composition of:

- current context;
- the next meaningful decision or action;
- one active thread from the season portfolio;
- physiological or calendar constraint only when consequential;
- a capture affordance;
- an explicit “nothing needs attention” state.

The Now surface is not a feed. New items do not push old items down indefinitely. It should rarely show more than three substantial objects at once.

Possible states include:

- **Clear:** the day is already coherent; show the shape and stay quiet;
- **Choice:** one trade-off needs attention;
- **Preparation:** a future event makes a current action unusually valuable;
- **Recovery:** capacity is the binding constraint;
- **Open:** unstructured time is available and should not automatically be filled;
- **Disrupted:** travel, illness, injury, crisis, or major plan change invalidates normal expectations.

### Map

A spatial view of the current life stage and season portfolio. It should show:

- active directions;
- foundation conditions;
- major commitments;
- current capabilities under development;
- upcoming landmarks;
- tension or dependency between paths;
- deliberately dormant areas.

It is not a project-management Gantt chart. A path can represent “build toward an exceptional next role,” “create real romantic opportunity,” or “run a sub-20-minute 5K,” but the map must visibly distinguish direction, experiment, commitment, and milestone.

### Archive

A temporal navigator across days, episodes, journeys, seasons, chapters, and eras. It should support two complementary modes:

- **Forensic:** inspect what happened, where a fact came from, and how a recommendation was formed;
- **Narrative:** experience the arc of a period through selected events, places, people, images, decisions, and reflections.

Narrative summaries must remain editable and must link back to evidence. Odyssey may propose “This appears to have been a turning point”; it must not canonize interpretations without user acceptance.

### Workshop

The place for deliberate configuration and analysis rather than daily operation:

- Charter and season editing;
- training-block design;
- intent rules and standing permissions;
- evidence inspection;
- experiment design;
- integration health;
- Trust Center;
- product-change proposals;
- data export, repair, and migration diagnostics.

On iPhone this can be a secondary destination. On iPad and Mac it becomes a first-class workspace.

## 18.3 Tomorrow Map

The Tomorrow Map is a generated preview, not a mandatory journal ritual.

It should combine:

- immutable commitments;
- tentative calendar blocks;
- expected sleep opportunity;
- training plan;
- travel and location transitions;
- current season priorities;
- unresolved decisions;
- preparation dependencies;
- meaningful people or events;
- likely high-friction transitions.

The default result should be one screen with:

- a short description of tomorrow’s shape;
- one likely pressure point;
- one preparation action with high leverage;
- one explicitly protected open period, when appropriate.

The system should generate this automatically when enough context exists. It should ask a question only when the answer would materially change tomorrow. “What is your top priority?” is prohibited when the current season and calendar already make the answer obvious.

## 18.4 Capture architecture

Capture must be ubiquitous but not modal. A global capture affordance should accept:

- typed or spoken note;
- food or drink;
- decision;
- commitment;
- observation;
- person/contact moment;
- idea;
- symptom or state;
- outcome/correction;
- photo or document reference.

Capture follows a two-stage pipeline:

1. **Immediate durable write:** store the original payload locally with timestamp, device, location permission state, and optional attachments;
2. **Asynchronous interpretation:** classify, extract entities, propose links, and request clarification only when the ambiguity matters.

Never block capture on a network request or model response. The original text/audio/image reference is immutable; all interpretations are versioned derivatives.

## 18.5 Decision surfaces

A normal decision card contains:

- the decision in one sentence;
- stakes: low, medium, high, or critical;
- why now;
- no more than three meaningful options by default;
- Odyssey’s recommendation, when confidence and value justify one;
- one-line reasoning;
- predicted consequences with uncertainty;
- actions: choose, adapt, defer, dismiss, or inspect;
- “what would change this?” when uncertainty is material.

Deep inspection can reveal:

- Charter/season alignment;
- calendar and health context;
- personal precedents;
- scientific evidence;
- omitted considerations;
- counterargument;
- model and rule provenance.

The default card must remain concise enough to use while standing on a platform or leaving the office.

## 18.6 Relationship experience

Relationships must not be presented as a ranked CRM pipeline.

Odyssey may represent:

- relationship kind and user-defined meaning;
- closeness as a private, coarse, editable category;
- commitments and important dates;
- last meaningful contact, not merely last message;
- shared experiences;
- current relational context such as “new friendship,” “close but geographically distant,” or “romantic exploration”;
- user-authored boundaries and sensitivities.

It should not infer affection from message volume, compute “relationship ROI,” rank romantic prospects, score compatibility, or recommend manipulating another person.

Useful surfaces include:

- “People who matter in this chapter” in the Archive;
- a gentle notice when an important commitment is at risk;
- a preparation prompt before a meaningful event;
- memory cues such as prior shared plans, only when contextually appropriate;
- an explicit private mode excluding selected relationship data from cloud AI.

## 18.7 History and season transitions

A season transition is a consequential model change and deserves ceremony without bureaucracy.

A transition flow should:

1. show what changed in behavior, context, or stated priorities;
2. summarize the outgoing season without grading the person;
3. identify unfinished commitments that must be carried, renegotiated, or released;
4. invite revision of Charter interpretation and portfolio weights;
5. generate a prospective transition plan;
6. preserve the prior version immutably;
7. begin with a two-week calibration period in which interventions are conservative.

The visual transition may change atmosphere, topography, and motion, but must keep core controls stable.

## 18.8 Accessibility and emotional safety

Accessibility is an architectural requirement:

- Dynamic Type without clipped charts or cards;
- VoiceOver labels that communicate state and consequence, not decorative coordinates;
- reduced motion alternatives;
- high-contrast and differentiate-without-color modes;
- haptics never used as the sole signal;
- plain-language alternatives for metaphorical views;
- no important action hidden exclusively in drag, hover, or spatial navigation;
- readable evidence and provenance at all supported text sizes.

Emotionally sensitive states require tone shifts. Illness, grief, rejection, injury, and relationship endings should suppress celebratory progress language and routine optimization prompts. A “low-demand mode” should be manually available and automatically suggested, never imposed.

---

# 19. Visual and art direction

## 19.1 Design thesis

The visual system should express **movement through a living landscape** while ordinary controls remain unmistakably native and usable.

The metaphor is best used for:

- orientation;
- time;
- dependency;
- distance;
- convergence and divergence;
- seasons and chapters;
- companions and shared episodes.

It should not replace buttons, forms, evidence tables, or permission explanations with game symbolism.

## 19.2 Spatial model

Use three spatial scales:

1. **Immediate terrain:** Now and Tomorrow; close, concrete, high contrast;
2. **Regional map:** current season and its paths; moderate abstraction;
3. **Atlas:** years of life; low-frequency, expansive, narrative.

Zooming between scales should preserve object identity. A race shown as a landmark on the season map should become an episode in the Archive and link to workouts, places, photos, decisions, and outcomes.

## 19.3 Visual grammar

### Paths

A path means a sustained direction or commitment, not a task list. Its thickness can communicate current allocation; texture can communicate uncertainty; branching can show a live decision. Avoid rendering every minor action as a waypoint.

### Landmarks

Landmarks are externally or internally meaningful events: an interview, race, journey, major conversation, deadline, or transition. They may be fixed, tentative, or aspirational, visibly distinguished.

### Weather and atmosphere

Atmosphere may encode state but must never imply moral judgment. Examples:

- mist = uncertainty or incomplete information;
- open horizon = slack and possibility;
- heavy terrain = genuine constraint or recovery load;
- dawn/dusk = temporal transition;
- changing foliage/material = season identity.

Do not map poor scores to ugly worlds or good scores to addictive reward effects.

### Constellations

Constellations are suitable for sparse, meaningful relationships among people, values, and events. They are not suitable for dense operational graphs.

## 19.4 Typography

Use Apple system typography for operational UI and a restrained editorial companion face for chapter titles and archive moments only. The implementation must not depend on custom fonts for legibility or core identity.

Typographic hierarchy:

- orientation statement;
- decision/action;
- consequence and confidence;
- supporting context;
- provenance and metadata.

Numbers should use tabular figures in comparisons and charts. Avoid giant metric numerals as the default visual center.

## 19.5 Color

Color is semantic and stateful:

- a stable neutral foundation across all seasons;
- a season palette with one dominant atmospheric hue and two restrained accents;
- fixed semantic colors for warning, uncertainty, destructive actions, and external commitment;
- user-selectable color-blind-safe palettes;
- no “red day / green day” total judgment.

Season transitions should alter palette gradually over days, not instantly reskin the product.

## 19.6 Materials and depth

Use native materials where they clarify hierarchy. The world/map layer may use subtle paper, topographic, glass, or luminous effects, but operational content must remain crisp.

Depth communicates:

- foreground = requires possible action;
- middle ground = relevant context;
- background = ambient orientation;
- buried/archived = retrievable but not demanding attention.

## 19.7 Motion

Motion has four jobs:

1. preserve object continuity across scales;
2. show consequence propagation;
3. communicate state transition;
4. acknowledge completion without reward theatrics.

Examples:

- choosing an option gently redirects a path;
- deferring a decision moves it along the timeline rather than making it vanish;
- updating a season shifts map emphasis;
- a consequence preview sends a subtle pulse toward future landmarks;
- archive aggregation folds events into an episode.

Do not use confetti, slot-machine anticipation, random reward, forced animations, or constant parallax. All significant motion requires a reduced-motion equivalent.

## 19.8 Charts and uncertainty

Charts must answer a decision question. Every chart should have a sentence title such as “Late caffeine is associated with shorter sleep in your last 12 comparable days,” not “Caffeine vs Sleep.”

Uncertainty should be visible through:

- intervals;
- sample count;
- comparable-day count;
- missingness;
- data-quality marks;
- alternative explanations;
- distinction between observation and experiment.

Avoid smooth trend lines through sparse data. Default to raw points plus robust summaries where practical.

## 19.9 Iconography and haptics

Use SF Symbols for system actions and a small custom symbol set only for Odyssey-specific concepts such as Season, Charter, Decision, Evidence, Experiment, and Chapter. Every custom symbol needs a text label at first encounter.

Haptics:

- light selection for changing an option;
- confirmation for durable capture;
- warning for an externally consequential action;
- no celebratory haptic loops;
- no background haptics for routine nudges.

## 19.10 Art-engine implementation

Implement stateful art as a token and scene system, not scattered conditional styling.

```text
VisualState
  seasonThemeId
  stageThemeId
  timeOfDayBand
  motionLevel
  focusMode
  accessibilityOverrides
  emotionalSafetyMode
  momentumBand?        // optional, never moralized
  locationContext?     // broad category, not raw coordinate
```

A `VisualThemeResolver` produces semantic tokens consumed by every platform. The resolver must be deterministic and snapshot-testable. Art assets are versioned, locally cached, and have a neutral fallback.

[EXPERIMENT] Build two map prototypes before committing:

- a calm 2D cartographic SwiftUI/Canvas implementation;
- a richer Metal/SpriteKit scene used only for orientation and Archive.

Choose the simplest version that remains emotionally resonant after a four-week dogfood period.

---

# 20. Apple ecosystem architecture

## 20.1 Platform allocation principle

Each surface should do what it is uniquely good at. Shared domain logic and design tokens are appropriate; identical feature sets are not.

## 20.2 iPhone

The iPhone is the primary operational surface for:

- Now;
- Tomorrow Map;
- capture;
- decision cards;
- health/nutrition logging;
- intent delivery;
- calendar-aware planning;
- quick Archive review;
- AI explanation and correction;
- integration and permission setup.

Implementation:

- SwiftUI application;
- unidirectional feature state with explicit reducers or equivalent deterministic state transitions;
- local SQLite repository;
- background sync coordinator;
- App Intents shared with widgets and Shortcuts;
- HealthKit/EventKit/Core Location adapters behind protocols;
- app-group snapshot store for extensions.

Avoid a cross-platform web shell. Native system integration, offline latency, widgets, watch, HealthKit, and accessibility justify native Swift.

## 20.3 Apple Watch

The Watch should support moments measured in seconds:

- current next action or state;
- “done / not now / changed” response;
- quick state capture: energy, pain, mood, caffeine, alcohol, meal, note;
- workout plan preview and launch where WorkoutKit permits;
- complication or Smart Stack glance;
- live workout contextual cues;
- arrival/departure capture only where platform and permission allow.

It should not contain the full Map, evidence library, season editor, or long AI conversation.

The Watch must remain useful without immediate network access. It writes local operations, syncs through WatchConnectivity or direct networking as available, and displays a cached compact state snapshot.

## 20.4 Widgets and controls

Widgets are ambient orientation, not miniature dashboards.

Recommended families:

- **Current Thread:** one sentence showing what matters now;
- **Tomorrow Shape:** next meaningful transition and preparation cue;
- **Training:** planned session, readiness caveat, and quick action;
- **Capture:** one-tap controls or App Intents for frequent records;
- **Season Compass:** current season and allocation, updated infrequently.

Widget timelines must be generated from cached deterministic state. Do not invoke a cloud LLM from a timeline provider. Because WidgetKit budgets refreshes and the extension is not continuously active, content must tolerate staleness and display “updated” semantics where material. [A03]

## 20.5 Live Activities and Dynamic Island

Use only for bounded, time-limited processes with a clear beginning and end:

- a workout;
- a travel transition;
- an active focus/preparation block;
- a time-sensitive cooking or recovery protocol;
- an interview-day sequence explicitly started by the user.

Do not keep a permanent “life score” Live Activity. Do not use Live Activities as a workaround for notification limits.

## 20.6 iPad

The iPad is suited to:

- season mapping;
- training-block planning;
- evidence exploration;
- relationship and journey reflection;
- archive browsing;
- scenario comparison;
- handwritten or keyboard reflection;
- review of product-change proposals.

Use multi-column navigation, pointer/keyboard support, drag-and-drop into plans, and Pencil annotations where they add value. The iPad client shares the local database and sync engine but can maintain richer derived caches.

## 20.7 Mac

The Mac is the professional and analytical workspace:

- career opportunity research;
- interview preparation plans;
- long-form Charter or season revision;
- data inspection and export;
- experiment analysis;
- evidence curation;
- integration diagnostics;
- archive editing;
- developer/debug tools in internal builds.

The Mac app should be a native SwiftUI client with AppKit bridges only where needed. It should support universal links/deep links from browser research and a share extension for capturing job descriptions, papers, routes, and articles.

## 20.8 HealthKit

Apple Health is canonical for standard health and fitness samples when suitable types exist:

- workouts;
- heart rate and resting heart rate;
- sleep stages and duration;
- body mass;
- active energy;
- dietary energy and macronutrients;
- caffeine and alcohol where supported;
- other user-approved measurements.

Odyssey owns:

- semantic food presets and recipes;
- meal meaning/context;
- training blocks and intended sessions;
- readiness interpretations;
- personal baselines and derived features;
- links from samples to decisions, experiments, and episodes;
- provenance describing which device/app supplied a sample.

Use anchored queries for incremental import and observer queries/background delivery where supported, but treat delivery as best effort. Deduplicate by HealthKit identifiers and source metadata. Never overwrite HealthKit data from another app. Writes made by Odyssey retain source links and can be reconciled after reinstall.

Health permissions must be requested incrementally at the moment a feature needs them, with a clear explanation of what becomes possible. Health-data routes to cloud AI are separately consented and visible in the Trust Center.

## 20.9 WorkoutKit

WorkoutKit can represent planned workouts and synchronize scheduled workouts to Apple Watch on supported OS versions. Use it as an execution surface, while Odyssey remains the source of training-block semantics and adaptation logic. [A02]

The adapter must tolerate:

- unsupported workout structures;
- user modifications in Apple systems;
- missed sessions;
- duplicate schedules;
- plan changes while offline.

## 20.10 EventKit

Calendar provides constraints and opportunities, not a complete account of intention.

Access policy:

- prefer write-only access when Odyssey only creates events;
- use system event-editing UI where that avoids broad permissions;
- request full access only for features that genuinely need reading;
- maintain a dedicated Odyssey calendar for tentative or generated blocks;
- never move or delete external-calendar events without explicit authorization;
- store EventKit identifiers as external references, not durable semantic IDs.

Calendar entries are mutable observations. The local event mirror should record source, last-seen version, cancellation, and time-zone semantics. Full calendar access is permission-sensitive and must degrade gracefully. [A04]

## 20.11 App Intents, Shortcuts, Spotlight, and Siri surfaces

Expose stable, narrow intents:

- Log Food;
- Log Caffeine;
- Log Alcohol;
- Capture Observation;
- Show What Matters Now;
- Start Planned Workout;
- Mark Intent Complete;
- Defer Decision;
- Open Tomorrow Map;
- Record Outcome;
- Enter Low-Demand Mode.

Intent implementations use local deterministic services and return promptly. Expensive interpretation is queued. Entities exposed to the system must avoid leaking sensitive relationship or health labels in suggestions by default.

App Shortcuts should make high-frequency actions immediately discoverable. Spotlight indexing should include user-approved public-safe objects such as books, places, races, projects, and chapters, not sensitive raw observations.

## 20.12 Core Location and Maps

Location is useful for place memory, travel, commuting context, and opportunity detection, but continuous high-precision tracking is not the default.

Use a tiered policy:

1. manually attached place;
2. foreground location;
3. significant-location changes / visits when justified;
4. temporary precise location for a user-started journey or workout;
5. continuous background GPS only for a bounded explicit activity.

Raw coordinates should be locally reduced into visits and place candidates where possible. Cloud upload follows the user’s location-data policy. Geofences are scarce and unreliable as a general intent engine; reserve them for a small number of high-value, current rules. Background location requires a legitimate feature and clear user-facing rationale. [A06]

Use MapKit for display and user-selected places. Do not create a hidden location surveillance layer merely because the product is private.

## 20.13 Photos

The Photos integration is for archive enrichment, not blanket image ingestion.

Prefer:

- user-selected assets through the system picker;
- on-device metadata and embedding/indexing where available;
- event/episode suggestions based on date and broad location;
- storing Photos identifiers and approved derivatives rather than copying originals.

Any face or relationship inference is opt-in, inspectable, and not sent to external models without explicit permission.

## 20.14 Notifications, Focus, and alarms

Notifications are a delivery channel, not the intent engine itself. The engine may decide an intervention is valuable; platform policy decides whether and how it can be delivered.

- Local notifications: deterministic future opportunities that can be scheduled in advance;
- Remote notifications: server-discovered or cross-device opportunities;
- Time-sensitive notifications: only when Apple’s semantics and user expectations are met;
- Critical alerts: out of scope unless a legitimate safety use case and entitlement exists;
- AlarmKit: explicit alarm/countdown experiences authorized by the user; not a loophole for wellness nagging;
- Focus: respect notification settings and use Focus filters or App Intents only through supported APIs.

AlarmKit may provide stronger delivery semantics for actual alarms, including behavior through Focus/silent settings after authorization, but it must never be used for ordinary recommendations. [A08]

## 20.15 Foundation Models framework

On-device models can support:

- private extraction and classification;
- capture cleanup;
- concise summarization;
- query rewriting;
- local explanation when the task fits capability;
- small structured transformations.

The app must check model availability and maintain a deterministic or cloud fallback. Do not make a core workflow dependent on Apple Intelligence eligibility, model download, or an unreleased OS feature. The framework supports guided structured output and tool use on compatible systems, but model calls remain asynchronous and fallible. [A09]

## 20.16 Availability strategy

- Compile with the latest stable Xcode for production releases.
- Establish a stable minimum deployment target based on device ownership, initially expected to be one to two major OS versions behind current.
- Encapsulate every platform capability behind an availability-aware adapter.
- Keep beta-only APIs in isolated packages/targets and disabled in production until the OS and tooling are public releases.
- Maintain a capability matrix per device rather than branching on OS version alone.

---

# 21. Integration strategy

## 21.1 Integration constitution

An integration should exist only when it provides one or more of:

- canonical data Odyssey should not recreate;
- materially lower capture friction;
- a decision-relevant signal unavailable elsewhere;
- a durable action surface the user already trusts;
- archive value that cannot be reconstructed later.

Every integration must have:

- supported first-party API or user-controlled import;
- declared sync direction;
- provenance and external IDs;
- rate-limit and outage behavior;
- permission scope;
- revocation behavior;
- data retention policy;
- deletion semantics;
- test fixture or sandbox strategy;
- maintenance owner and value metric.

No credential theft, browser automation against private surfaces, or brittle scraping.

## 21.2 Integration tiers

### Tier 0 — platform core

Build in the first two editions:

- Apple Health / HealthKit;
- Calendar / EventKit;
- App Intents and Shortcuts;
- Notifications and ActivityKit;
- Core Location / MapKit at conservative scope;
- WeatherKit or another supported weather source;
- Photos picker and share extension;
- Contacts for explicit person selection and stable references.

### Tier 1 — high-value supported services

Add once the core data and sync substrate is stable:

- Strava: activity import, routes, and social/training context through OAuth and webhooks;
- GitHub: contribution and repository activity relevant to career learning, using official APIs;
- a supported running or race-calendar source if it adds data absent from HealthKit;
- reading services with documented APIs or exports;
- travel itineraries through authorized email parsing or supported provider APIs;
- an email/calendar provider only where Apple-native data is insufficient.

### Tier 2 — selective enrichment

Require a written value case and prototype:

- music listening history;
- meditation applications;
- bank/open-banking data;
- weight-scale vendor APIs;
- nutrition databases;
- airline/hotel APIs;
- location-history imports;
- browser-history or reading-history ingestion.

### Tier 3 — prohibited or intentionally avoided

- LinkedIn scraping or automated applications outside official permitted APIs;
- dating-app scraping, automated swiping, or message generation/sending;
- covert message analysis of other people;
- continuous microphone capture;
- workplace systems without explicit authorization;
- integrations that require storing a third-party password;
- services whose terms prohibit the intended use.

## 21.3 Canonical ownership table

| Domain | Canonical system | Odyssey responsibility |
|---|---|---|
| Standard health samples | Apple Health | import references, semantic links, derived features |
| Calendar events | user’s calendar provider through EventKit | context mirror, interpretation, tentative Odyssey calendar |
| Contacts | Contacts | private relationship semantics and durable internal person ID |
| Photos | Photos | approved references, episode links, summaries |
| Workouts | HealthKit / source service | plan semantics, block structure, adaptation, outcomes |
| Food presets | Odyssey | entries may write nutrient samples to HealthKit |
| Season/Charter | Odyssey | full source of truth and history |
| Decisions/intents | Odyssey | full source of truth and audit trail |
| Scientific literature | publisher/identifier plus Odyssey evidence store | claim extraction, appraisal, mappings, cached legal metadata |
| Job opportunity | Odyssey plus captured source document | research, decisions, pipeline; no silent external submission |
| Financial transactions | regulated aggregator/bank | normalized references and derived summaries only after opt-in |

## 21.4 Integration health

The Workshop must expose for each connector:

- last successful sync;
- newest source timestamp;
- lag;
- permission state;
- token expiry or refresh failure;
- number of rejected or quarantined records;
- schema-version mismatch;
- rate-limit state;
- deletion/revocation option;
- “what Odyssey currently believes this source contributes.”

An integration that fails silently is worse than no integration.

## 21.5 Import and export

Support user-controlled imports for:

- CSV/JSON/ZIP;
- GPX/FIT/TCX where relevant;
- Health export subsets;
- calendar files;
- Markdown/text journals;
- location history exports;
- training plans;
- bookmarks/reading lists.

Import is staged:

1. upload or local select;
2. immutable source registration and hash;
3. parser version recorded;
4. preview and mapping;
5. normalized records written to a quarantine namespace;
6. validation and deduplication;
7. merge approval;
8. import report and reversible batch ID.

Export must include raw and normalized data, attachments/manifests, schema versions, provenance, and human-readable Markdown/HTML summaries. Odyssey data must not become hostage to the application.

---

# 22. Data architecture

## 22.1 Architecture thesis

Use a **fact-and-event ledger with relational projections**, not pure CRUD and not dogmatic event sourcing.

The ledger preserves durable observations, assertions, and changes. Relational current-state tables and materialized views make ordinary queries efficient. External raw payloads are retained in object storage or local attachment storage where lawful and useful.

The source-of-truth hierarchy is:

1. original external or user-provided observation;
2. immutable normalized fact/event revision;
3. accepted semantic assertion;
4. derived features and summaries;
5. current-state projections;
6. model-generated hypotheses.

A lower layer must never be overwritten by a higher layer.

## 22.2 Identity

Use UUIDv7 identifiers for Odyssey-owned objects to provide globally unique, roughly time-ordered IDs. Every device gets a durable device ID stored in Keychain and registered with the backend.

External identifiers are stored as scoped references:

```text
ExternalReference
  id
  entity_id
  provider
  account_id
  external_type
  external_id
  source_revision?
  first_seen_at
  last_seen_at
  deleted_at?
```

Never use an EventKit, HealthKit, Strava, or Contacts identifier as the primary Odyssey identity.

## 22.3 Time model

Every temporally meaningful record should distinguish as applicable:

- `occurred_at` / interval — when the real-world event happened;
- `observed_at` — when a sensor/person observed it;
- `recorded_at` — when Odyssey persisted it;
- `valid_from` / `valid_to` — when an assertion was considered true;
- `effective_from` / `effective_to` — when a plan or rule applies;
- `source_updated_at` — when an external system says it changed;
- `timezone_id` and original local offset;
- precision: exact, minute, day, approximate range, unknown.

All instants are stored in UTC plus original zone metadata. Calendar-local concepts such as “bedtime on Tuesday” retain local-date semantics rather than being flattened into UTC only.

## 22.4 Provenance

Every fact, assertion, feature, recommendation, and summary carries a provenance envelope:

```text
Provenance
  source_kind: user | device | integration | import | rule | model | researcher
  source_id
  source_version
  actor_id
  device_id?
  observed_at?
  recorded_at
  transformation_chain[]
  model_run_id?
  confidence?
  consent_scope?
```

Transformation chains link derivatives to inputs through immutable IDs and code/model versions. The product must answer “Why does Odyssey believe this?” with concrete lineage.

## 22.5 Core storage groups

### Ledger

- `ledger_events`
- `assertions`
- `assertion_revisions`
- `retractions`
- `source_records`
- `import_batches`
- `attachments`

### Life model

- `charters`
- `charter_versions`
- `life_stages`
- `seasons`
- `season_portfolio_items`
- `directions`
- `commitments`
- `projects`
- `capabilities`
- `skills`

### Situations and actions

- `situations`
- `decisions`
- `decision_options`
- `decision_evaluations`
- `choices`
- `actions`
- `intents`
- `intervention_opportunities`
- `interventions`
- `outcomes`

### People and places

- `people`
- `relationship_assertions`
- `relationship_contexts`
- `places`
- `visits`
- `shared_experiences`

### Health and activity semantics

- `health_external_refs`
- `food_items`
- `food_presets`
- `meal_entries`
- `training_blocks`
- `planned_sessions`
- `session_outcomes`
- `derived_health_features`

### Evidence and learning

- `sources`
- `source_versions`
- `claims`
- `claim_appraisals`
- `claim_links`
- `personal_observations`
- `hypotheses`
- `experiments`
- `experiment_assignments`
- `experiment_measurements`
- `learnings`

### Memory and narrative

- `episodes`
- `episode_members`
- `chapters`
- `chapter_versions`
- `summaries`
- `embeddings`
- `semantic_edges`

### Product operation

- `sync_operations`
- `devices`
- `permissions`
- `standing_authorizations`
- `model_runs`
- `tool_calls`
- `recommendation_feedback`
- `product_events`
- `product_change_proposals`
- `experiments_product`

## 22.6 Assertions rather than mutable truth

Facts likely to change or be disputed should be modeled as assertions:

```text
Assertion
  subject_id
  predicate
  object_value_or_entity_id
  valid_interval
  source_provenance
  confidence
  epistemic_status
  supersedes_id?
  retracted_at?
```

Examples:

- “Divy’s current primary season direction is career acceleration.”
- “Person P is a close friend.”
- “Food F contains approximately 420 kcal per serving.”
- “Late caffeine appears associated with shorter sleep.”

This permits multiple sources, changed meanings, uncertainty, and historical queries without overwriting the past.

## 22.7 Semantic graph

Use a relational edge table:

```text
SemanticEdge
  from_entity_id
  edge_type
  to_entity_id
  valid_from
  valid_to?
  weight?
  confidence?
  provenance_id
  derived_by_version?
```

Common edges:

- `SERVES_DIRECTION`
- `DEPENDS_ON`
- `CONSTRAINS`
- `INVOLVES_PERSON`
- `OCCURRED_AT_PLACE`
- `PRECEDES`
- `CONTRIBUTED_TO`
- `SUPPORTED_BY_CLAIM`
- `CONTRADICTS`
- `MEMBER_OF_EPISODE`
- `SUPERSEDES`

The graph is a retrieval and explanation projection. Canonical semantics remain in typed domain tables and assertions.

## 22.8 Raw versus normalized versus derived

- **Raw:** exact imported payload or capture; immutable, optionally compressed/encrypted;
- **Normalized:** stable Odyssey representation with source mapping;
- **Derived:** reproducible feature, classification, summary, or edge;
- **Curated:** user-accepted semantic interpretation;
- **Ephemeral:** cache or recommendation context that may be regenerated.

Every derived record stores `derivation_version`, input IDs/hashes, and computation time. A migration or model upgrade creates a new version rather than silently changing historical output.

## 22.9 Local database

Use SQLite through GRDB or an equivalently mature Swift library with:

- explicit migrations;
- value observation;
- transactions;
- WAL mode;
- FTS5;
- custom functions where justified;
- encryption/data-protection integration;
- testable SQL;
- backup APIs.

Core Data/SwiftData are acceptable for UI-only caches but are not recommended as the authoritative local store because Odyssey needs explicit temporal schemas, sync operations, migration control, and forensic queryability.

## 22.10 Cloud database

Use PostgreSQL 18 or the current stable supported version at implementation time, with:

- range types and exclusion constraints for temporal intervals;
- JSONB for raw provider fragments, not as a substitute for schema;
- row-level security as defense in depth;
- pgvector for embeddings;
- full-text search;
- partitioning only after measured need;
- logical replication or CDC only when a concrete consumer exists;
- migration tooling such as Alembic;
- read replicas only after workload evidence.

Do not depend on beta database features for bitemporal correctness. Implement explicit valid-time columns and history tables.

## 22.11 Object storage

Store:

- original imports;
- audio captures after user-approved retention;
- document snapshots;
- generated archive assets;
- model/evaluation artifacts;
- encrypted backup bundles;
- large raw provider payloads.

Every object has:

- content hash;
- MIME type;
- encryption state;
- source/license classification;
- retention class;
- owner entity;
- deletion tombstone;
- object-store version ID.

## 22.12 Data quality

Quality is not a binary flag. Record dimensions:

- completeness;
- temporal precision;
- source reliability;
- sensor/source consistency;
- suspected duplication;
- plausibility;
- user correction status;
- derivation freshness.

A recommendation engine must be able to require minimum quality thresholds rather than treating all available data as equally credible.

---

# 23. Backend architecture

## 23.1 Reference deployment

The preferred reference architecture is:

- **Cloud Run** for stateless HTTP services and workers;
- **Cloud SQL for PostgreSQL** for the durable relational core;
- **Cloud Storage** for objects, exports, and backups;
- **Cloud Tasks** for scheduled/retryable asynchronous work;
- **Pub/Sub** only for event fan-out that truly has multiple consumers;
- **Secret Manager** for credentials;
- **Artifact Registry** for containers;
- **OpenTelemetry** exported to a chosen trace/metric/log backend;
- **Terraform/OpenTofu** for infrastructure;
- **GitHub Actions or an environment-neutral CI contract** for builds and tests.

This is a reference, not a philosophical dependency on Google Cloud. The repository must run locally through Docker Compose and keep portable boundaries around object storage, queues, and model providers.

## 23.2 Service shape

Begin as a modular monolith with separately deployable worker processes, not microservices.

```text
odyssey-api
  auth
  sync
  life-model
  decision
  intent
  archive
  evidence
  integrations
  ai-orchestration
  telemetry
  admin/diagnostics

odyssey-worker
  scheduled-jobs
  integration-sync
  derivations
  embeddings
  evidence-ingestion
  archive-synthesis
  evaluation
  notification-dispatch
```

Modules own schemas and interfaces, but share one database and deployment. Extract a service only when there is a proven scaling, security, release-cadence, or fault-isolation need.

## 23.3 API style

Use HTTP/JSON with OpenAPI 3.1 and generated typed clients where useful.

Primary API groups:

- `/v1/sync/*`
- `/v1/context/*`
- `/v1/decisions/*`
- `/v1/intents/*`
- `/v1/captures/*`
- `/v1/seasons/*`
- `/v1/evidence/*`
- `/v1/archive/*`
- `/v1/integrations/*`
- `/v1/trust/*`
- `/v1/telemetry/*`
- `/v1/admin/*` for owner-only diagnostics.

GraphQL is not recommended initially. The clients need deterministic synchronization and bounded use-case endpoints, not arbitrary public query composition.

## 23.4 Transactional outbox

Any database transaction that requires asynchronous follow-up writes an outbox record in the same transaction. Workers claim and process outbox records idempotently.

Examples:

- new health feature → recompute readiness context;
- accepted decision → prepare action and schedule outcome check;
- new source document → parse and appraise claims;
- season update → invalidate projections and generate transition draft;
- revoked permission → cancel jobs and purge disallowed derivatives.

Do not publish to a queue before the corresponding database write commits.

## 23.5 Job semantics

Cloud Tasks and similar systems provide at-least-once delivery. Every job handler must therefore have:

- idempotency key;
- deduplication record;
- bounded retry policy;
- retryable versus terminal error classification;
- deadline;
- lease/heartbeat for long work;
- dead-letter or quarantine state;
- operator-visible trace;
- compensation strategy for external side effects.

Scheduled time means “not before,” not exact execution. Timing-sensitive interventions need a delivery window and expiry check at execution.

## 23.6 Authentication

For a one-user system:

- Sign in with Apple is the preferred user authentication;
- backend allowlists the single Apple subject after bootstrap;
- recovery path uses encrypted owner recovery material and documented runbook;
- devices are separately enrolled and can be revoked;
- access tokens are short-lived;
- refresh/device credentials are stored in Keychain/Secure Enclave where appropriate;
- service-to-service identity uses cloud workload identity, not long-lived JSON keys.

An owner/admin interface must never rely on obscurity or a hardcoded email address alone.

## 23.7 Authorization

Policy decisions consider:

- user identity;
- device trust;
- data sensitivity;
- requested scope;
- standing permission;
- action authority level;
- model/tool identity;
- consent route;
- time and resource bounds.

The AI runtime receives capability-scoped tool tokens rather than database credentials. Tools return only the fields needed for the task.

## 23.8 Research/evidence ingestion

A dedicated pipeline handles:

1. source registration by DOI, PMID, URL, or file;
2. metadata retrieval through lawful APIs;
3. content availability/licensing classification;
4. text extraction from user-provided or legally accessible material;
5. claim candidate extraction;
6. human/model appraisal draft;
7. citation span storage;
8. deduplication and version tracking;
9. domain mapping;
10. periodic retraction/correction checks where APIs permit.

Do not build an indiscriminate web crawler. Scientific claims used operationally need source-level traceability and legal acquisition.

## 23.9 Notification service

The backend stores intervention opportunities and delivery decisions separately.

```text
Opportunity -> Policy decision -> Delivery plan -> APNs/local schedule -> Receipt -> Interaction -> Outcome
```

A notification payload contains minimal sensitive information. The client fetches details after authentication or uses encrypted content where practical. APNs delivery is not proof the user saw the item.

## 23.10 Cost and operational limits

Set explicit budgets:

- monthly model spend;
- per-workflow token/time budget;
- external API calls;
- storage growth;
- notification volume;
- background job concurrency;
- evidence refresh cadence.

The system should degrade in order:

1. reuse caches;
2. delay non-urgent enrichment;
3. use smaller models;
4. omit decorative synthesis;
5. retain deterministic core behavior.

Never fail food logging, capture, or basic planning because an AI budget is exhausted.

---

# 24. AI and model architecture

## 24.1 Architectural boundary

The AI layer is a set of bounded cognitive services. It does not own canonical state or side-effect authority.

Deterministic software owns:

- temporal arithmetic;
- permissions;
- notification budgets;
- hard constraints;
- source retrieval;
- state transitions;
- scoring formulas;
- experiment assignment;
- database writes;
- externally consequential actions.

Models may:

- extract structured candidates;
- synthesize retrieved context;
- compare options;
- generate counterarguments;
- explain rules and evidence;
- identify plausible patterns;
- propose experiments;
- draft summaries;
- classify product friction;
- propose product changes.

## 24.2 One orchestrator, many capabilities

Do not build a society of named agents. Implement one orchestration runtime with a capability registry.

```text
Capability
  name
  input_schema
  output_schema
  allowed_models
  allowed_tools
  data_sensitivity
  max_latency
  max_cost
  required_evidence
  evaluation_suite
  fallback_behavior
```

Examples:

- `capture_interpretation`
- `decision_synthesis`
- `consequence_explanation`
- `evidence_claim_extraction`
- `archive_episode_draft`
- `product_hypothesis_generation`
- `research_question_planning`

This structure permits provider changes without pretending all models are interchangeable.

## 24.3 Provider adapter

Define a narrow provider interface:

```text
ModelProvider.generateStructured(request) -> StructuredResult
ModelProvider.generateText(request) -> TextResult
ModelProvider.embed(batch) -> EmbeddingResult
ModelProvider.rerank(query, documents) -> RankedResult
ModelProvider.moderate?(content) -> PolicyResult
```

The adapter normalizes:

- model ID and snapshot;
- token usage;
- latency;
- finish reason;
- tool calls;
- refusal/error categories;
- structured-output validation;
- provider request ID;
- retention/data-routing policy.

Provider abstraction must not erase unique capabilities. Capability configuration can intentionally depend on a provider after a recorded ADR.

## 24.4 Direct API versus agent framework

Core recommendation and intervention flows should use direct model APIs with application-owned loops because Odyssey must control state, retrieval, permissions, and tool dispatch precisely.

A higher-level agent SDK may be used for bounded, observable workflows such as:

- compiling a company research dossier;
- comparing a set of papers;
- preparing a season-review artifact;
- executing an approved multi-step import repair.

No framework receives unrestricted access to the user’s data or external accounts. Framework traces must be exportable into Odyssey’s model-run schema. [M01–M04]

## 24.5 Structured outputs

All state-changing or recommendation-critical outputs use versioned schemas. Example:

```json
{
  "recommendation": "Go to bed within 20 minutes",
  "confidence": 0.72,
  "stakes": "medium",
  "reasons": [
    {"kind": "personal_observation", "ref": "obs_..."},
    {"kind": "calendar_constraint", "ref": "event_..."}
  ],
  "counterfactuals": [
    {"condition": "Tomorrow's interval session is cancelled", "effect": "stakes_low"}
  ],
  "uncertainties": ["Sleep onset time is estimated"],
  "suggested_action": {"type": "start_wind_down"}
}
```

Validate with JSON Schema/Pydantic/Swift generated types. Reject unknown schema versions. A prose answer may be rendered only after the structured object passes policy and evidence checks.

## 24.6 Retrieval pipeline

Use structured-first retrieval:

1. resolve user/session/season and authorization scope;
2. parse the question into temporal and entity constraints;
3. query typed relational data;
4. expand a small semantic-edge neighborhood;
5. retrieve semantically similar episodes/documents if needed;
6. rerank by relevance, recency, season, evidence quality, and source diversity;
7. create a compact evidence pack with citations and exclusions;
8. generate;
9. verify factual claims against the pack;
10. store the run, inputs, and output lineage.

Do not use vector similarity as the first or only retrieval strategy. “What happened before my best interval sessions?” is primarily a temporal/structured query.

## 24.7 Context assembly

Every model context has sections with explicit authority:

- **system policy**;
- **current task and output schema**;
- **accepted user Charter/season facts**;
- **current state with freshness**;
- **retrieved personal evidence**;
- **scientific claims with confidence**;
- **tool descriptions and limits**;
- **untrusted captured content**;
- **known uncertainties**.

Untrusted external documents are delimited and prohibited from changing tool permissions or system rules. Prompt-injection resistance is a data-flow requirement, not a single instruction string.

## 24.8 Model routing

Route by task characteristics:

- deterministic parser/rules for simple entities and thresholds;
- on-device model for private, low-risk, bounded text transformations;
- small cloud model for extraction/classification;
- stronger cloud model for consequential synthesis and research;
- embedding model for semantic retrieval;
- optional reranker for evidence selection.

Routing considers:

- sensitivity;
- connectivity;
- latency target;
- cost;
- schema reliability;
- reasoning complexity;
- current model evaluations;
- provider status.

Never route a task solely because a model is newest.

## 24.9 Tool model

Tools are typed functions with:

- least-privilege data scope;
- read/write classification;
- authority level;
- idempotency semantics;
- confirmation requirement;
- rate limit;
- audit record;
- simulation mode.

A model can propose a tool call. The policy engine authorizes it. The user confirms when required. The executor performs it and records the exact result. The model never fabricates success.

## 24.10 Long-running reasoning

Research and archive jobs may be resumable workflows. Persist:

- workflow plan;
- completed steps;
- citations/source set;
- intermediate artifacts;
- cost and time consumed;
- checkpoints;
- cancellation state;
- final evaluation.

Use a durable workflow library or application-owned state machine only when jobs exceed ordinary queue semantics. Do not adopt a complex orchestration platform merely to run three API calls.

## 24.11 Model and prompt registry

Each production invocation records:

- capability version;
- prompt/template hash;
- model snapshot;
- provider;
- tool schema versions;
- retrieval policy version;
- generation parameters;
- safety/policy version;
- experiment cohort;
- outcome feedback.

Prompts and schemas live in version control. Production configuration is declarative and reviewable. Rollback must not require a client release.

## 24.12 Hallucination controls

For factual recommendations:

- require cited inputs;
- distinguish retrieved fact from model inference;
- use claim-level verification for high-stakes output;
- reject unsupported numbers and dates;
- provide “insufficient evidence” as a valid output;
- include a counterevidence search for consequential advice;
- cap recommendation strength by evidence confidence and data freshness;
- never invent a personal pattern from fewer than the configured minimum comparable observations.

## 24.13 On-device intelligence

Apple Foundation Models and smaller Core ML models are complementary, not replacements for the cloud intelligence layer.

Suitable local tasks:

- capture routing;
- sensitive entity extraction;
- offline summary of a short local record;
- intent phrase parsing;
- private search-query expansion;
- low-risk UI copy adaptation.

Cloud remains appropriate for:

- literature research;
- cross-domain synthesis over large evidence packs;
- advanced temporal scenario comparison;
- model-based evaluations;
- archive generation across years.

## 24.14 AI failure behavior

Every capability specifies one of:

- deterministic fallback;
- cached result with freshness label;
- reduced-quality local model;
- defer and retry;
- explicit unavailability.

Do not replace an uncertain AI answer with generic motivational prose. When the system cannot reason reliably, it should show known facts or remain silent.

---

# 25. Offline and synchronization strategy

## 25.1 Local-first contract

The following must work without network access:

- opening Now with last-known state;
- all manual capture;
- food preset lookup and logging;
- planned workout view;
- decision review and local choice;
- calendar/HealthKit queries available on device;
- basic rules and scores;
- cached evidence inspection;
- app settings and trust controls;
- export request staging;
- queueing corrections and deletions.

Cloud-only features may include fresh research, expensive cross-year synthesis, third-party web integrations, and server-scheduled reasoning.

## 25.2 Operation log

Every local write produces an operation:

```text
SyncOperation
  operation_id: UUIDv7
  device_id
  device_sequence
  entity_type
  entity_id
  mutation_type
  base_revision?
  payload
  created_at
  idempotency_key
  sensitivity_class
  sync_state
```

The local transaction writes both domain state and operation. Sync uploads batches in sequence, and the server returns accepted revisions plus a global cursor.

## 25.3 Server change log

The server exposes changes after a cursor:

```text
GET /v1/sync/changes?cursor=...
POST /v1/sync/push
```

The response includes:

- canonical revision;
- originating device/operation;
- tombstones;
- merge result;
- conflicts requiring attention;
- next cursor;
- server time and schema version.

Use compact batches and resumable paging. Sync is idempotent across retries.

## 25.4 Merge policies

Do not use one last-write-wins rule for all data.

- **Append-only observations:** union by operation ID/content hash;
- **Counters/sets:** deterministic commutative merge where applicable;
- **Editable notes:** preserve both revisions and offer merge on conflict;
- **Charter/season:** optimistic concurrency; never silently merge normative text;
- **Decisions/choices:** first accepted choice becomes current, later choice is an explicit revision;
- **Food presets:** field-level merge when edits do not overlap; otherwise retain versions;
- **Permissions/standing authorizations:** most restrictive state wins until user resolves;
- **Deletions:** tombstone with deletion epoch; do not resurrect from stale device;
- **External mirrors:** source-revision precedence plus local semantic overlays.

A CRDT library is unnecessary initially. Introduce one only for a data type with real concurrent editing pressure.

## 25.5 Clock and timezone safety

Device clocks are untrusted for ordering. Use device sequence for local order and server receipt/revision for global order. Preserve original timestamps but detect implausible clock skew.

Travel requires:

- original timezone;
- current timezone;
- event semantic zone;
- local-day reassignment rules;
- explicit handling of daylight-saving transitions;
- no assumption that a “day” is always 24 hours.

## 25.6 Attachment sync

Attachments use content-addressed, resumable upload:

1. create metadata and hash locally;
2. request signed upload URL;
3. upload chunks;
4. verify checksum;
5. commit object reference;
6. retain local copy according to cache/retention policy.

Sensitive attachments may be client-side encrypted before upload. The encryption key policy must be documented alongside recovery consequences.

## 25.7 Extensions and shared state

Widgets, Watch, and App Intents should not open the full database in unsafe concurrent patterns. Maintain an app-group snapshot containing only:

- current thread;
- next transition;
- selected quick actions;
- lightweight training state;
- freshness and redaction flags.

The main app updates snapshots transactionally after relevant state changes. Extensions can append small capture operations to an inbox for later ingestion.

## 25.8 Conflict UX

Most conflicts should be resolved automatically by domain rules. User-facing conflicts should explain meaning, not database mechanics:

> “Your Mac changed the season end date to 30 November after your iPhone changed it to 15 December. Keep one date or create a new revision?”

Do not present raw JSON diffs for ordinary use, though internal diagnostics should retain them.

## 25.9 Sync observability

Expose:

- last successful push/pull;
- operations queued;
- oldest unsynced operation;
- conflict count;
- schema compatibility;
- attachment backlog;
- device cursor;
- server cursor;
- repair/rebuild option.

An internal “rebuild projections from ledger” command must be tested before launch.

---

# 26. Notification and background strategy

## 26.1 Three-layer execution model

Odyssey must separate:

1. **Opportunity detection** — there may be a useful moment;
2. **Intervention policy** — interruption is worth its cost;
3. **Delivery mechanism** — what the platform can reliably do.

Conflating these layers produces brittle claims such as “notify exactly ten minutes after waking.”

## 26.2 Opportunity sources

Opportunities may be generated by:

- a known future calendar boundary;
- a local HealthKit update;
- app foregrounding;
- significant location/visit update;
- completion of an action;
- server-side scheduled reevaluation;
- third-party webhook;
- a user-started Live Activity;
- a background refresh that happens to run;
- a Watch interaction.

Every opportunity has a validity window. Late opportunities expire rather than becoming nonsensical notifications.

## 26.3 Delivery planner

The planner chooses among:

- no delivery; update ambient state only;
- show next time the app opens;
- update widget/control snapshot;
- local notification scheduled in advance;
- remote push;
- Live Activity update;
- Watch complication/Smart Stack state;
- user-authorized alarm;
- bundle into a later digest.

The planner respects:

- notification budget;
- Focus and quiet hours;
- recent dismissals;
- current device and likely surface;
- urgency and expiry;
- sensitivity on lock screen;
- duplicate suppression;
- user standing preferences.

## 26.4 Background execution constraints

`BGAppRefreshTask` and `BGProcessingTask` are opportunistic. The system chooses execution time; processing can be interrupted. Use them for:

- synchronization;
- cache refresh;
- derivations;
- maintenance;
- precomputing tomorrow when time permits.

Do not use them as the sole mechanism for a deadline. Maintain expiration handlers and checkpoint work. [A07]

HealthKit background delivery and location events can wake the app in supported circumstances, but they are not universal clocks. APNs can prompt content updates, but delivery remains best effort. The product language and tests must reflect this.

## 26.5 Local scheduling

When a future time is already known, schedule a local notification immediately and include a cancellation/update key. Examples:

- an explicitly chosen wind-down reminder;
- preparation before a fixed interview;
- medication only if the product later meets appropriate safety requirements;
- departure prompt derived from a calendar event and route estimate.

Reconcile scheduled requests whenever calendar, timezone, or intent state changes. Maintain a registry because iOS limits pending requests.

## 26.6 Server reevaluation

The server runs coarse reevaluation at meaningful windows, not minute-by-minute polling. It can:

- detect cross-domain consequences;
- incorporate web integrations and weather;
- select candidate opportunities;
- send a silent/content push or visible push when justified;
- mark an opportunity for foreground display.

At delivery time the client rechecks local state and suppresses stale advice.

## 26.7 Waking and inferred states

“After waking” should be modeled as uncertain state inference:

- sleep session ended;
- device became active;
- first meaningful movement;
- first unlock/app interaction;
- user-confirmed wake state;
- calendar/time plausibility.

The system should wait for sufficient confidence within a window. When confidence is weak, phrase the prompt as an option rather than a claim, or wait until app open.

## 26.8 Notification budget defaults

Initial conservative defaults:

- maximum two proactive visible notifications on an ordinary day;
- zero is normal;
- one additional high-stakes item may exceed the budget;
- repeated dismissal of a class lowers its priority immediately;
- no streak-loss, guilt, or escalating copy;
- no follow-up on a dismissed item unless circumstances materially change;
- notification experiments require a control condition and explicit review.

These are product defaults, not permanent truths; tune through one-user experimentation.

## 26.9 Copy contract

Default proactive copy:

- line 1: actual stakes or reason;
- line 2: one suggested action;
- action buttons: specific and reversible.

Example:

> **Medium stakes tonight.** A third late night is likely to make Tuesday’s intervals harder.  
> Start a 20-minute wind-down, or mark tomorrow as flexible.

Avoid:

- “You’re falling behind”;
- false precision;
- moral language;
- unexplained scores;
- multiple paragraphs;
- fake urgency;
- claims that a notification was “AI-powered.”

## 26.10 Delivery evaluation

For each intervention class track:

- opportunities detected;
- policy suppressions and reason;
- notifications delivered;
- opens/actions/dismissals;
- time to action;
- user usefulness rating sampled sparingly;
- counterfactual/control outcomes where possible;
- later correction or regret;
- interruption cost proxy;
- channel and device.

The success metric is useful decisions per interruption, not click-through rate.

---
# 27. Observability

## 27.1 Observability goals

Odyssey needs observability for three distinct questions:

1. **Is the software healthy?**
2. **Did the intelligence reach its answer correctly?**
3. **Was the product behavior useful and appropriate?**

These concerns share correlation IDs but must not be collapsed into one analytics stream.

## 27.2 Technical telemetry

Instrument clients and backend with OpenTelemetry-compatible traces, metrics, and structured logs. [D04]

### Client signals

- launch duration and time to interactive;
- database-open and migration duration;
- screen rendering and main-thread stalls;
- crash and hang diagnostics;
- sync batch latency and failure;
- HealthKit/EventKit query latency;
- background task start, expiry, and completion;
- widget timeline age;
- notification scheduling/reconciliation errors;
- battery/thermal-sensitive work counters;
- model call latency and fallback.

### Backend signals

- request rate, latency, and error by endpoint;
- database pool and query latency;
- queue depth, age, retries, and dead letters;
- integration lag and provider errors;
- APNs attempts and provider responses;
- model latency, tokens, cost, schema failures, refusals;
- retrieval result count and source diversity;
- cache hit rate;
- backup age and restore-test status;
- migration state;
- object storage failures;
- authorization denials and anomalous access.

## 27.3 Trace model

A user-visible recommendation should have one trace graph:

```text
opportunity_detected
  -> context_snapshot_built
  -> retrieval_query
  -> evidence_pack_built
  -> model_or_rule_evaluation
  -> policy_gate
  -> delivery_plan
  -> notification_or_surface_render
  -> interaction
  -> action
  -> outcome_observation
```

Each span records IDs and versions, not unrestricted sensitive payloads. A privileged diagnostic viewer can resolve referenced records after owner authentication.

## 27.4 AI trace

Store a `ModelRun` with:

- capability and version;
- purpose;
- prompt-template hash;
- model/provider snapshot;
- retrieval IDs and hashes;
- redaction/data route;
- tool requests and results;
- structured output;
- validation errors/retries;
- policy result;
- latency/cost;
- user feedback;
- downstream outcome link.

Raw prompts and completions can contain deeply sensitive data. Retention must be configurable by capability. For production debugging, prefer reconstructable references and encrypted short-term samples over indefinite plaintext logging.

## 27.5 Service-level objectives

Initial SLOs:

| Capability | Target |
|---|---:|
| Local capture durability | 99.99% successful local commit excluding device storage failure |
| Local food-preset search p95 | <100 ms |
| Now cached render p95 | <400 ms after process start; <100 ms warm |
| Local decision action commit p95 | <150 ms |
| Sync API availability | 99.9% monthly |
| Sync convergence | 95% within 60 seconds when foreground and connected; 99% within 15 minutes |
| Server decision synthesis p95 | <8 seconds for interactive use |
| Notification candidate freshness | 99% evaluated before expiry for server-owned windows >15 min |
| Restore drill | successful at least quarterly |
| Unsupported scientific citation in production evaluation | <1%, target 0 for high-stakes classes |

These targets are starting contracts and should be revised from measurements. AI latency must never block local state mutation.

## 27.6 Alerts

Alert on conditions requiring action, not every transient error:

- no successful backup beyond threshold;
- restore verification failure;
- sync backlog increasing for several hours;
- migration stuck or mixed incompatible schemas;
- model schema-failure rate above baseline;
- external integration authorization failure;
- notification dispatch failure for high-stakes class;
- unexpected cost spike;
- security anomaly;
- data-quality quarantine growth;
- client crash regression in current build.

Because there is one user, an internal diagnostics inbox can often replace a large on-call apparatus, but critical data-integrity alerts need an external channel independent of Odyssey.

## 27.7 Reproducibility bundle

Every reported issue should allow an encrypted diagnostic bundle containing:

- app/build and schema versions;
- capability matrix;
- relevant trace IDs;
- redacted event timeline;
- sync state;
- migration history;
- feature flags;
- model/config versions;
- optional user-selected record payloads.

The user previews the bundle before export. Debug export must never silently include all personal history.

---

# 28. Product telemetry and self-improvement

## 28.1 Telemetry is question-driven

Do not instrument generic “engagement.” Start with a product question and define the minimum events needed to answer it.

Example:

> **Question:** Does the Tomorrow Map reduce uncertainty without becoming a nightly chore?

Required signals:

- whether a map was automatically available;
- whether it was opened;
- whether it prompted a manual edit;
- time spent;
- next-day plan deviations;
- sampled usefulness/friction response;
- whether the user opened it only after a notification;
- days where it was intentionally absent.

“Daily active” alone cannot answer the question.

## 28.2 Event schema

```text
ProductEvent
  event_id
  occurred_at
  received_at
  session_id?
  device_id
  app_build
  surface
  event_name
  object_type?
  object_id_pseudonymous?
  context_version
  feature_flag_assignments
  properties_typed
  causal_parent_event_id?
  local_only_flag
```

Use a governed event registry with owner, purpose, property schema, sensitivity class, and retention. Reject unknown properties in development and flag them in production.

## 28.3 Core product questions

Instrument to answer:

- Which naturally occurring decision points bring the user to Odyssey?
- Which recommendations produce action, useful reconsideration, or irritation?
- Which manual inputs become expensive on busy days?
- Which data is collected but never used?
- Which widget or Watch glance precedes useful action?
- Which explanations are expanded, and why?
- Which suggestions are consistently corrected?
- Where does the user leave a workflow?
- Which features are used from habit versus actual value?
- When does Odyssey remain silent, and was silence appropriate?
- Does the system preserve spontaneous high-quality days?
- Which current inferences have become stale?
- How often are actions reversed?
- Which provider or model changes alter recommendation behavior?

## 28.4 Feedback capture

Feedback mechanisms should be low-friction and situated:

- useful / not useful;
- wrong context;
- bad timing;
- already handled;
- too intrusive;
- reasoning wrong;
- fact wrong;
- preference changed;
- “show me less like this”;
- free-text correction.

A correction is first-class data. It should update the relevant assertion or preference candidate, not disappear into an analytics warehouse.

## 28.5 Product hypothesis engine

A weekly or on-demand analysis can propose hypotheses:

```text
ProductChangeProposal
  observed_pattern
  supporting_events
  alternative_explanations
  proposed_change
  predicted_benefit
  risk
  reversibility
  evaluation_plan
  confidence
  status: proposed | approved | running | rejected | adopted | reverted
```

Example:

> On six busy weekdays, meal logging was abandoned after the search step. Most completed logs used one of eight presets. Proposal: surface the top four context-matched presets directly on the capture sheet for two weeks.

The proposal must show sample size and counterexamples. No UI, score, or notification policy changes silently.

## 28.6 Product experiments

Because there is one user, classic parallel A/B testing is often impossible. Use:

- randomized decision points for low-risk notifications;
- alternating-week or crossover designs;
- stepped introduction;
- historical replay before live exposure;
- interrupted time series with explicit confound notes;
- qualitative interviews/reflections;
- reversal where effects are reversible.

Product experiments need predeclared outcomes and stop rules. Do not optimize click-through when the desired outcome is lower cognitive burden.

## 28.7 Preventing self-reinforcing loops

Telemetry can create a popularity trap: frequently used features receive investment and important rarely used capabilities disappear. Countermeasures:

- classify features by expected frequency;
- evaluate “critical when needed” separately from habitual use;
- retain user-stated strategic value;
- inspect non-use reasons;
- distinguish friction from irrelevance;
- include season changes;
- never infer “does not matter” solely from low event count.

## 28.8 Product-change governance

Changes are classified:

- **safe auto-tuning:** cache size, ranking tie-breaker, nonsemantic layout spacing;
- **proposal required:** notification timing, workflow steps, score weights, recommendation tone;
- **explicit Charter/authority review:** season priorities, standing permissions, relationship semantics, data routes;
- **release/ADR required:** schema semantics, storage, model-provider policy, deletion behavior.

A change log should explain what Odyssey changed, why, and how to revert it.

---

# 29. Evaluation framework

## 29.1 Evaluation layers

Use six layers:

1. deterministic unit/property tests;
2. dataset-based component evaluations;
3. end-to-end historical replay;
4. adversarial and safety scenarios;
5. live shadow evaluation;
6. longitudinal real-use evaluation.

No model or rule is promoted solely because individual examples “look good.”

## 29.2 Evaluation dataset structure

An evaluation case contains:

```text
EvalCase
  case_id
  scenario_time
  frozen_context_snapshot
  permitted_data_scope
  question_or_trigger
  expected_invariants
  acceptable_outputs
  unacceptable_outputs
  evidence_requirements
  authority_limit
  evaluator_rubric
  provenance
```

Maintain:

- synthetic cases;
- de-identified/reconstructed real cases;
- exact historical snapshots with owner permission;
- regression cases from every substantive failure.

## 29.3 Recommendation-quality rubric

Evaluate:

- relevance to current situation;
- alignment with Charter and season;
- recognition of constraints;
- consequence plausibility;
- evidence appropriateness;
- personalization without overclaiming;
- viable alternative generation;
- uncertainty calibration;
- brevity and actionability;
- respect for autonomy;
- non-moralizing tone;
- silence when intervention has negative value.

High-stakes classes require independent evidence and policy checks beyond model grading.

## 29.4 Retrieval evaluation

Metrics:

- fact recall at k;
- temporal correctness;
- source precision;
- provenance completeness;
- stale-record rate;
- contradictory-source coverage;
- season-scope correctness;
- sensitive-data leakage;
- retrieval latency;
- evidence diversity.

Construct tests such as:

- same person, multiple relationships over time;
- changed preference;
- travel across time zones;
- corrected food nutrition;
- duplicated workout from HealthKit and Strava;
- old season that must not dominate current advice;
- conflicting scientific claims;
- intentionally excluded memory.

## 29.5 Scientific-claim evaluation

For each claim in a recommendation assess:

- exact source support;
- population and intervention match;
- study type correctly represented;
- effect size/uncertainty not exaggerated;
- evidence grade;
- retraction/correction status;
- distinction between association and causation;
- personal applicability;
- citation span fidelity.

The evaluator should be partly deterministic and partly expert/model-assisted. A second model is not a source of truth; it is a triage tool.

## 29.6 Temporal consequence evaluation

Replay historical days and ask:

- Were all material future commitments retrieved?
- Were consequences ordered by magnitude and time?
- Did the engine distinguish accumulation from one-off deviation?
- Did it account for recovery and uncertainty?
- Did it overstate causality?
- Would the advice remain coherent if a key assumption changed?
- Did it identify “low stakes” and remain quiet appropriately?

Use counterfactual variants with one changed fact to test sensitivity rather than memorized prose.

## 29.7 Intervention evaluation

Primary metrics:

- net usefulness rating;
- useful actions per visible interruption;
- regret/correction rate;
- bad-timing rate;
- duplicate/redundant rate;
- over-intervention and under-intervention rates;
- time-to-action when action is appropriate;
- effect on distal/proximal outcome where estimable;
- autonomy burden.

An ignored notification is not automatically failure. The user may have acted without opening it, already known the information, or rationally declined.

## 29.8 Calibration

Where the system emits confidence or probability, measure:

- reliability diagrams;
- Brier score for probabilistic outcomes;
- selective accuracy when abstaining;
- confidence versus evidence quality;
- stability across model versions.

User-facing confidence should use calibrated bands with explanations. Never display 73% merely because a model generated `0.73`.

## 29.9 Human review

Create a review queue for sampled consequential outputs and every correction involving:

- factual error;
- scientific overclaim;
- sensitive relationship inference;
- external-action attempt;
- unexplained high confidence;
- harmful tone;
- permission boundary issue.

For a one-user product, the owner can review selected cases during weekly/monthly protocols. The implementation agent should provide compact review artifacts, not raw trace dumps.

## 29.10 Model-change gate

Before changing a production model or prompt:

1. run deterministic tests;
2. run capability-specific golden set;
3. compare against incumbent;
4. inspect regressions, not only average scores;
5. run historical replays;
6. estimate cost/latency;
7. shadow in production where possible;
8. enable by feature flag;
9. retain instant rollback;
10. monitor corrections and schema failures.

A newer model does not automatically replace an older one.

## 29.11 Product North Star evaluation

At one month, score the product—not the user—on:

- decision usefulness;
- cognitive effort saved minus effort imposed;
- trust calibration;
- intervention restraint;
- data durability;
- capture friction reduction;
- archive value emerging naturally;
- preservation of spontaneity;
- adaptation to changed context;
- number of serious errors or boundary violations.

This score is a review instrument and must not become a vanity dashboard.

---

# 30. Security model

## 30.1 Threat model

Protect against:

- stolen or unlocked device;
- compromised cloud credentials;
- leaked API keys;
- malicious or vulnerable third-party integration;
- prompt injection in emails, documents, and web content;
- accidental overbroad model context;
- developer logging sensitive payloads;
- supply-chain compromise;
- unauthorized build or backend deployment;
- data corruption presented as truth;
- exfiltration through AI tools;
- account recovery failure;
- malicious link/attachment;
- insider access in a managed development environment.

This is a private system, not a low-risk system. Its data concentration makes it unusually sensitive.

## 30.2 Data classification

Classify fields and objects:

- **Public:** intentionally shareable;
- **Private:** ordinary personal data;
- **Sensitive:** health, location, finances, career applications, private reflections;
- **Highly sensitive:** relationship details, intimate health, credentials, raw communications, identity documents;
- **Operational secret:** tokens, keys, certificates;
- **Derived sensitive:** inferences that may be more revealing than raw inputs.

Classification controls storage, logs, AI routing, export, notification redaction, and retention.

## 30.3 Encryption

- TLS 1.3 where supported for network traffic;
- platform data protection for local files and SQLite;
- Keychain for credentials and keys;
- cloud-provider encryption at rest plus customer-managed keys only if operational benefit justifies complexity;
- application-level envelope encryption for highly sensitive fields or attachments that should not appear in database plaintext;
- encrypted backups and export bundles;
- key rotation runbook;
- no secrets in source control, build logs, crash reports, or prompt templates.

End-to-end encryption for all cloud data would materially constrain server-side AI and search. Do not claim it unless designed and tested. Instead allow selected memories/attachments to be local-only or client-side encrypted and excluded from cloud intelligence.

## 30.4 Least privilege

- each backend workload has a separate service identity;
- database roles are module/workload scoped;
- integration tokens are per connector and encrypted;
- AI tools receive short-lived capability tokens;
- Terraform state is protected;
- production access is separate from development;
- no shared admin token;
- read-only diagnostics by default;
- destructive repair requires step-up authentication and explicit backup checkpoint.

## 30.5 Prompt-injection defenses

Treat all captured and retrieved content as untrusted data.

- system and policy instructions live outside retrieved text;
- documents are content-delimited;
- models cannot elevate tool authority;
- tool calls are schema-validated and policy-gated;
- external content cannot request secrets;
- URL fetching uses allowlists/egress policy and content limits;
- model output is never executed as code or SQL;
- research agents run with read-only tools by default;
- suspicious instructions in source documents are surfaced in traces;
- side effects require an independent authorization path.

## 30.6 Client security

- use App Attest/DeviceCheck where it meaningfully protects backend endpoints;
- certificate pinning is optional and should be adopted only with a safe rotation strategy;
- redact sensitive app-switcher snapshots;
- allow biometric lock for selected spaces or whole app;
- do not place sensitive details in notification payloads by default;
- use secure coding/decoding and reject unexpected object types;
- validate deep links;
- separate internal debug menus from production entitlements;
- disable production logging of raw personal payloads.

## 30.7 Supply chain

- lock dependencies and review updates;
- generate SBOMs for backend and app where tooling permits;
- scan containers and dependencies;
- verify build provenance/signing;
- minimize third-party mobile SDKs, particularly analytics SDKs;
- prefer direct OpenTelemetry export over opaque tracking libraries;
- pin GitHub Actions by commit or use trusted equivalents;
- use automated secret scanning;
- maintain dependency removal plan.

## 30.8 Security testing

Before a broadly connected edition:

- static analysis;
- dependency scanning;
- API authorization tests;
- mobile data-storage inspection;
- prompt-injection test suite;
- SSRF/file-parser fuzzing;
- backup confidentiality test;
- lost-device/revocation drill;
- integration-token revocation drill;
- privilege review;
- external penetration test when exposure and value justify it.

## 30.9 Incident response

Runbooks must cover:

- credential leak;
- compromised device;
- model provider exposure concern;
- malicious integration payload;
- corrupted recommendation history;
- lost database;
- accidental deletion;
- unauthorized external action;
- dependency compromise.

The owner should be able to enter “local-only / pause integrations / pause proactive interventions” mode from a trusted device or recovery console.

---

# 31. Data durability, schema evolution, and migrations

## 31.1 Durability objective

Odyssey-owned history is a long-lived personal asset. Development convenience must never make destructive reset the normal migration strategy.

Durability requires:

- redundant local/cloud copies;
- recoverable backups;
- versioned schemas;
- immutable raw sources;
- tested migrations;
- export independent of running services;
- documented disaster recovery;
- integrity verification.

## 31.2 Backup layers

### Device

- regular SQLite online backup to an app-managed protected file;
- encrypted owner-triggered export;
- optional iCloud device backup subject to platform behavior;
- pre-migration backup checkpoint;
- retained last-known-good local snapshots within storage budget.

### Cloud database

- Cloud SQL automated backups;
- point-in-time recovery enabled;
- daily logical dump to separate object-storage bucket/project;
- retention tiers, for example 35 daily, 12 monthly, and annual archive as appropriate;
- backup encryption and access audit;
- quarterly restore into isolated environment.

### Objects

- object versioning or soft delete;
- lifecycle retention;
- cross-region or separate-account copy for essential archives;
- manifest hash verification;
- deletion workflow that respects user intent across versions.

## 31.3 Recovery objectives

Initial targets:

- RPO: under 15 minutes for committed cloud data; zero for unsynced local operations if the device survives;
- RTO: under four hours for cloud restoration, under one working day for a complete clean-room rebuild;
- local app remains usable during cloud restoration;
- no backup considered valid until restored and integrity-checked.

## 31.4 Schema migration policy

Every migration is:

- monotonic and uniquely identified;
- backward-compatible during a declared mixed-version window where feasible;
- tested against anonymized large fixture and the previous production snapshot shape;
- resumable or transactional;
- measured for duration and storage amplification;
- accompanied by projection-rebuild logic;
- included in export schema documentation.

Destructive column removal uses expand/migrate/contract:

1. add new representation;
2. dual-read/dual-write or derive;
3. backfill with provenance;
4. verify counts/hashes/semantic invariants;
5. switch readers;
6. retain old data through rollback window;
7. contract only after backup and acceptance.

## 31.5 Semantic migrations

Changing meaning is more dangerous than changing a column.

Examples:

- redefining “meaningful contact”;
- altering a score;
- changing how a season is considered active;
- merging people;
- changing food-serving units;
- revising readiness interpretation.

A semantic migration creates a new derivation or assertion version and preserves prior results. Historical displays should indicate the model applicable at the time or offer recalculated and original views.

## 31.6 Model-derived data migration

When replacing a model:

- do not rewrite all summaries automatically;
- classify derivatives as ephemeral, historical artifact, or canonical user-accepted;
- regenerate ephemeral caches freely;
- retain historical model output with version;
- never replace user-edited/accepted text without a diff and approval;
- run re-embedding incrementally with dual-index support;
- evaluate retrieval before switching indexes.

## 31.7 Integrity checks

Scheduled checks:

- foreign-key and exclusion constraints;
- ledger/projection count reconciliation;
- source hash verification;
- orphaned attachment detection;
- sync sequence continuity;
- tombstone consistency;
- HealthKit/external-reference deduplication;
- object manifest validation;
- encrypted object decrypt test on a sample;
- backup freshness;
- provenance chain reachability.

An integrity failure creates a visible incident and freezes destructive compaction.

## 31.8 Data deletion

Deletion is explicit by scope:

- hide from attention;
- retract an assertion;
- delete a derived summary;
- disconnect an integration and stop future sync;
- delete imported source batch;
- delete all Odyssey-owned data;
- request deletion from model/provider logs where contract permits.

Because provenance and backups complicate erasure, the UI must explain timing and residual encrypted backup retention. Tombstones prevent resurrection. Legal/commercial compliance is still relevant even for a one-user project.

## 31.9 Clean-room restoration

The repository must include a scripted drill:

1. provision empty infrastructure;
2. restore database to selected point;
3. restore object manifest/data;
4. apply current migrations;
5. verify checksums and invariants;
6. rotate secrets;
7. enroll a fresh client;
8. reconcile local unsynced operations;
9. generate restore report;
10. destroy test environment securely.

---

# 32. Failure modes and pre-mortem

Assume Odyssey has been abandoned after six months. The following are the most plausible causes.

## 32.1 Manual capture became a second job

**Early signal:** logging completion collapses on travel, busy days, or social evenings.

**Root causes:** too many fields, asking for precision that does not change decisions, failure to learn presets, model clarification loops.

**Mitigations:** durable raw capture first; progressive interpretation; one-tap presets; infer low-value fields; explicitly support “rough but useful”; track time-to-log; remove fields unused in decisions.

## 32.2 Notifications became nagging

**Early signal:** rapid dismissal, notification permissions disabled, irritation feedback, lower app opens after pushes.

**Root causes:** optimizing engagement, ignoring opportunity cost, repeated advice, treating all goals as active.

**Mitigations:** conservative budgets; silence gate; suppression reasons; expiry; randomized low-risk testing; weekly intervention review; no guilt copy.

## 32.3 Advice sounded intelligent but was wrong

**Early signal:** factual corrections, citations that do not support claims, implausible personal patterns.

**Root causes:** vector-only retrieval, stale context, uncited generation, model overconfidence.

**Mitigations:** structured-first retrieval; evidence packs; claim verification; abstention; provenance UI; model gates; regression suite from every correction.

## 32.4 The product was slow because everything invoked AI

**Early signal:** capture latency, abandoned sheets, blank widgets, timeouts.

**Root causes:** cloud calls in critical path, no cached state, oversized prompts.

**Mitigations:** local-first transactions; deterministic projections; asynchronous enrichment; latency budgets; cached narratives; provider fallbacks.

## 32.5 Scores became oppressive or gameable

**Early signal:** behavior aimed at points, anxiety over exceptions, avoiding untracked experiences, manual correction to protect score.

**Root causes:** universal score, opaque weights, streaks, moral colors.

**Mitigations:** plural explanatory indicators; no total Life Score; context-specific denominators; exception handling; measure score reaction; feature flag and removal criteria.

## 32.6 Personalization became stale identity

**Early signal:** “That is not me anymore,” repeated dismissals after season change, old relationships resurfacing incorrectly.

**Root causes:** no temporal scope or expiry, behavior treated as preference, embeddings without versioned semantics.

**Mitigations:** scoped assertions; decay/reconfirmation; surprise affordance; transition calibration period; stale-inference review.

## 32.7 Relationship support felt transactional or invasive

**Early signal:** avoidance of People features, discomfort with rankings, inappropriate message suggestions.

**Root causes:** CRM metaphors, message-volume metrics, hidden inference.

**Mitigations:** coarse user-owned semantics; no ranking/ROI; explicit boundaries; local-only modes; focus on commitments and shared experiences.

## 32.8 Beautiful art became a gimmick

**Early signal:** map avoided for direct lists, motion disabled beyond accessibility needs, novelty fades.

**Root causes:** metaphor replacing usability, excessive animation, changing navigation with season.

**Mitigations:** plain-language navigation; stable controls; map limited to orientation/archive; four-week prototype trial; reduced visual mode.

## 32.9 Integrations constantly broke

**Early signal:** stale data, OAuth failures, repeated duplicate records, maintenance consumes roadmap.

**Root causes:** too many providers, undocumented APIs, canonical ownership unclear.

**Mitigations:** tiering; first-party APIs; connector contracts; health dashboard; graceful disablement; value review; delete low-value integrations.

## 32.10 Cloud architecture consumed the project

**Early signal:** more infrastructure code than product loops, expensive idle services, release fear.

**Root causes:** premature microservices, multiple databases, heavyweight agent platform.

**Mitigations:** modular monolith; Postgres plus object storage; one queue abstraction; portable local stack; extract only from measured need.

## 32.11 Apple background assumptions failed

**Early signal:** missed context windows, stale widgets, reminders after the event.

**Root causes:** treating best-effort APIs as exact schedulers.

**Mitigations:** opportunity windows; local pre-scheduling; server fallback; foreground recheck; visible freshness; tests on physical devices and low-power states.

## 32.12 Data was lost during development

**Early signal:** reset instructions in release notes, migration crashes, mismatched projections.

**Root causes:** destructive migrations, no restore drill, treating TestFlight builds as disposable.

**Mitigations:** pre-migration backup; ledger/projection separation; PITR; export; migration fixtures; release gates; quarterly restore.

## 32.13 Odyssey over-optimized life

**Early signal:** every open period receives a recommendation; spontaneous events feel like deviations; user stops sharing data.

**Root causes:** objective maximization, no slack model, attention-seeking product incentives.

**Mitigations:** protected open time; spontaneity as a constraint; silence output; post-hoc appreciation rather than pre-optimization; measure cognitive burden.

## 32.14 Career features became a generic applicant tracker

**Early signal:** pipeline maintenance without better preparation or decisions.

**Root causes:** copying SaaS ATS patterns, tracking quantity over opportunity quality.

**Mitigations:** opportunity thesis, role/company research, preparation learning loop, decision journal, explicit quality criteria, no application-volume score.

## 32.15 The system was abandoned after five days of non-use

**Early signal:** return screen is overwhelming, backlog of prompts, scores punish absence.

**Root causes:** assuming continuity, accumulating stale decisions.

**Mitigations:** re-entry mode that summarizes change, expires stale items, asks at most one material question, and offers a clean restart without guilt.

## 32.16 A provider or account became unavailable

**Early signal:** model errors, API shutdown announcement, OAuth revocation.

**Mitigations:** capability/provider registry; exportable data; deterministic fallbacks; queued work; integration isolation; documented migration path; no provider-specific IDs as primary keys.

## 32.17 Sensitive information leaked through logs or models

**Early signal:** raw text in traces, lock-screen exposure, broad provider retention.

**Mitigations:** classification; redaction; local processing; retention controls; security tests; Trust Center; provider contracts; field-level encryption.

## 32.18 The system inferred causality from noise

**Early signal:** rapidly changing “insights,” contradictory recommendations, effects based on tiny samples.

**Root causes:** uncontrolled correlation mining, multiple testing, regression to mean.

**Mitigations:** minimum samples; shrinkage; preregistered N-of-1 experiments; confound display; effect stability checks; hypothesis language; false-discovery controls for exploratory analysis.

## 32.19 The archive fabricated a life story

**Early signal:** confident turning points the user rejects, omitted difficult events, model-generated quotes.

**Root causes:** narrative coherence prioritized over truth.

**Mitigations:** source-linked drafts; uncertainty; editable interpretations; no fabricated dialogue; alternative narrative lenses; original evidence always reachable.

## 32.20 Success criterion for the pre-mortem

The architecture is not successful because these failures are listed. Every mitigation must map to:

- an implementation requirement;
- a telemetry signal;
- a test or evaluation;
- an owner-visible control;
- a recovery path.

---

# 33. Technology choices and alternatives considered

## 33.1 Native client language and UI

**Choice:** Swift 6.x, SwiftUI, structured concurrency.

**Why:** deepest Apple API access, watch/widgets/intents, performance, accessibility, offline capability.

**Alternatives:** React Native, Flutter, web/PWA.

**Rejected initially because:** extension ecosystems and new Apple APIs require extensive native bridging; cross-platform reuse is low-value when all target platforms are Apple.

## 33.2 Local persistence

**Choice:** SQLite with GRDB.

**Why:** explicit SQL, migrations, observation, WAL, FTS, forensic access, sync control.

**Alternatives:** SwiftData/Core Data, Realm.

**Decision:** SwiftData may be used for disposable UI caches only. Realm adds vendor/runtime complexity without a demonstrated need.

## 33.3 Cloud relational store

**Choice:** PostgreSQL with pgvector.

**Why:** transactions, temporal range support, JSONB, full text, vectors, mature backup tooling, portability.

**Alternatives:** Firestore, DynamoDB, CloudKit-only, dedicated event store.

**Rejected as core:**

- Firestore complicates joins, temporal/provenance queries, and local custom sync;
- CloudKit-only constrains backend reasoning, integrations, and portability;
- a specialist event store adds operations and projection burden before scale demands it.

## 33.4 Graph storage

**Choice:** relational edge tables and derived graph views.

**Alternative:** Neo4j or managed graph database.

**Deferral criterion:** adopt a graph engine only if measured traversal workloads remain slow or unmaintainable after query/index optimization and graph semantics are stable.

## 33.5 Vector storage

**Choice:** pgvector in Postgres.

**Alternatives:** Pinecone, Weaviate, Qdrant, Milvus.

**Why defer specialist vector DB:** one user, moderate corpus, fewer operational systems, transactional metadata filters. Revisit when corpus/latency/evaluation shows need.

## 33.6 Backend language

**Choice:** Python 3.13+ with FastAPI, Pydantic, SQLAlchemy/Alembic, async where justified.

**Why:** model/research ecosystem, data science, rapid structured services, strong typing tooling.

**Alternative:** Swift server, Go, Kotlin, TypeScript.

**Open design:** latency-sensitive or highly concurrent connector workers may later be Go; do not split languages without evidence.

## 33.7 Cloud

**Reference choice:** Google Cloud Run + Cloud SQL + Cloud Storage + Cloud Tasks.

**Alternatives:** AWS, Azure, Fly.io, Railway, Supabase, Firebase, self-hosted Kubernetes.

**Why:** low idle operations, managed Postgres, task scheduling, portable containers. Kubernetes is explicitly deferred. Supabase is viable for rapid provisioning but should not become a dependency on proprietary client sync/auth if it weakens the chosen architecture.

## 33.8 API

**Choice:** REST/JSON + OpenAPI, dedicated sync protocol.

**Alternatives:** GraphQL, gRPC.

**Why:** simple native integration and operational visibility. gRPC may later serve internal high-throughput paths; GraphQL provides little value for one controlled client family.

## 33.9 Queue and workflow

**Choice:** transactional outbox + Cloud Tasks for ordinary jobs.

**Alternatives:** Pub/Sub everywhere, Temporal, Celery, custom cron.

**Decision:** use Pub/Sub only for true fan-out. Evaluate Temporal or equivalent only for workflows with multi-hour/days duration, compensation, and many checkpoints that become painful in application state machines.

## 33.10 AI orchestration

**Choice:** custom thin orchestration layer over direct provider APIs; optional agent SDK adapter for bounded workflows.

**Alternatives:** fully commit to OpenAI Agents SDK, Anthropic SDK patterns, Google ADK, LangGraph, Semantic Kernel, homegrown generalized agent framework.

**Rationale:** Odyssey needs precise retrieval, permissions, provenance, and evaluation. Framework lock-in is not justified for core loops; supported SDKs can accelerate selected workflows if traces and authority boundaries remain under Odyssey control.

## 33.11 Model providers

**Choice:** capability-based registry with at least one primary cloud provider and one tested fallback for critical non-proprietary workflows; Apple on-device models where supported.

**Do not choose permanently in architecture.** Select models through current evaluations at implementation time. Provider contracts, data retention, regional processing, structured-output reliability, latency, and cost are first-class criteria.

## 33.12 Observability

**Choice:** OpenTelemetry instrumentation with pluggable exporter.

**Alternatives:** provider-specific SDK only.

**Why:** correlated traces across app/backend/AI without making a monitoring vendor part of the domain model.

## 33.13 Infrastructure as code

**Choice:** Terraform or OpenTofu modules plus Docker Compose for local development.

**Alternatives:** console setup, Pulumi, cloud-native deployment templates.

**Why:** reproducible credential-free implementation and documented handoff. Pulumi is acceptable if the implementation team strongly prefers a typed language and preserves portability.

## 33.14 Analytics

**Choice:** product-event table in Postgres initially, transformed with SQL/dbt-like jobs into review views; no third-party consumer analytics SDK.

**Alternatives:** Amplitude, Mixpanel, PostHog.

**Why:** one user, sensitive data, custom questions, and the need to connect telemetry to decisions/outcomes. A self-hosted/product platform may be added only when it clearly reduces analysis burden.

## 33.15 Feature flags

**Choice:** database-backed signed configuration with local cache and deterministic assignment.

**Alternative:** commercial flag service.

**Why:** one user and offline operation. Preserve kill switches and audit trail. Do not overbuild experimentation infrastructure.

## 33.16 Search

**Choice:** SQLite FTS locally; Postgres full text + vector + structured filters in cloud.

**Alternatives:** Elasticsearch/OpenSearch.

**Deferral:** introduce a search service only after query volume/corpus complexity warrants it.

---

# 34. Repository architecture

## 34.1 Monorepo

Use one repository to preserve cross-layer schemas, fixtures, and atomic changes.

```text
odyssey/
  README.md
  LICENSE
  SECURITY.md
  CODEOWNERS
  Makefile
  .editorconfig
  .env.example
  docs/
    constitution.md
    architecture/
      system-context.md
      data-model.md
      sync-protocol.md
      ai-boundaries.md
      apple-capabilities.md
      security-threat-model.md
    adr/
    runbooks/
    product/
      season-model.md
      intervention-policy.md
      evaluation-protocols.md
    deployment/
    source-register/
  schemas/
    jsonschema/
    openapi/
    events/
    generated/
  apple/
    Odyssey.xcworkspace
    Apps/
      iOS/
      Watch/
      macOS/
    Extensions/
      Widgets/
      Intents/
      Share/
    Packages/
      OdysseyDomain/
      OdysseyData/
      OdysseySync/
      OdysseyHealth/
      OdysseyCalendar/
      OdysseyLocation/
      OdysseyIntelligence/
      OdysseyDesignSystem/
      OdysseyTelemetry/
      OdysseyTesting/
    Resources/
    Config/
    Tests/
      Unit/
      Integration/
      Snapshot/
      UI/
  backend/
    pyproject.toml
    src/odyssey/
      api/
      auth/
      sync/
      domain/
      decision/
      intent/
      evidence/
      archive/
      integrations/
      ai/
      telemetry/
      jobs/
      db/
    migrations/
    tests/
      unit/
      integration/
      contract/
      evals/
    scripts/
  infra/
    modules/
    environments/
      dev/
      staging/
      prod/
    docker/
    compose.yaml
  evals/
    cases/
    rubrics/
    datasets/
    reports/
    replay/
  research/
    manifests/
    appraisal-templates/
  tools/
    codegen/
    data-repair/
    importers/
    export/
    diagnostics/
  fixtures/
    synthetic-life/
    integrations/
  .github/workflows/ or ci/
```

## 34.2 Module boundaries

- `OdysseyDomain` contains pure value types, policies, and no Apple/framework imports;
- `OdysseyData` owns SQLite repositories and migrations;
- platform adapters implement domain protocols;
- `OdysseyIntelligence` owns local deterministic context and provider-neutral client interfaces, not API secrets;
- backend modules cannot write another module’s tables except through a documented service/repository interface;
- shared schemas generate Swift/Python types where practical;
- no UI module imports raw SQL or provider SDKs.

## 34.3 Architecture decision records

Record decisions with:

- context;
- options;
- decision;
- consequences;
- evidence;
- reversal trigger;
- date/status.

Mandatory ADRs include:

- source-of-truth hierarchy;
- local persistence choice;
- cloud platform;
- sync conflict semantics;
- AI provider routing;
- sensitive-data encryption;
- location policy;
- score introduction;
- graph/vector service introduction;
- external-action authority.

## 34.4 Generated code

Generate:

- OpenAPI clients;
- JSON Schema/Pydantic/Swift models where stable;
- event registry documentation;
- database enum mappings if safe;
- capability matrix documentation.

Generated files are deterministic and checked in only where Xcode/build ergonomics require it. CI verifies regeneration produces no diff.

## 34.5 Configuration

Use layered typed configuration:

- compile-time capabilities/entitlements;
- nonsecret app config;
- environment config;
- secrets;
- remote feature policy;
- per-user standing permissions.

A startup diagnostics page must display effective nonsecret configuration and flag missing capabilities.

## 34.6 Seed and synthetic data

The repository includes a rich synthetic life dataset spanning:

- ordinary work weeks;
- travel;
- race training;
- illness;
- interviews;
- relationships;
- season transition;
- timezone changes;
- conflicting and missing data;
- several years of archive.

No real personal data belongs in source control.

---

# 35. Testing strategy

## 35.1 Test pyramid

### Pure domain tests

Test:

- score formulas;
- decision importance;
- authority levels;
- silence gate;
- intent windows;
- temporal overlap;
- timezone behavior;
- evidence confidence;
- merge policies;
- notification budgets.

Use property-based tests for temporal and sync invariants.

### Persistence tests

- every migration from all supported versions;
- transaction rollback;
- WAL/recovery;
- backup/restore;
- projection rebuild;
- large-history performance;
- tombstone and conflict semantics;
- FTS and vector metadata filters.

### Contract tests

- Swift client versus OpenAPI schema;
- provider adapters against recorded fixtures;
- integration webhook signature and idempotency;
- APNs payload constraints;
- model structured outputs;
- export/import round trip.

### Integration tests

- HealthKit using test data and protocol fakes;
- EventKit permission states;
- WatchConnectivity disconnection/replay;
- widget app-group snapshots;
- backend with real Postgres/object-store emulator;
- queue retries;
- OAuth refresh and revocation;
- model timeout/fallback.

### UI tests

Prioritize critical journeys:

- first capture offline;
- create and revise season;
- log common food in seconds;
- inspect and correct recommendation;
- revoke an integration;
- resolve sync conflict;
- recover after five days away;
- export data;
- enable low-demand mode.

## 35.2 Device matrix

Test on:

- smallest supported iPhone;
- current flagship iPhone;
- at least one older supported device;
- Watch paired/unpaired/offline;
- iPad compact and large layouts;
- Apple Silicon Mac;
- low power mode;
- constrained network;
- no Apple Intelligence availability;
- denied and partial permissions;
- multiple locale/timezone settings;
- Dynamic Type accessibility sizes;
- VoiceOver and reduced motion.

Simulators are insufficient for HealthKit background delivery, Watch behavior, notification timing, battery, and location. Maintain physical-device test scripts.

## 35.3 Sync chaos tests

Simulate:

- two devices editing the same season offline;
- device clock wrong by days;
- duplicate upload after timeout;
- operation applied but response lost;
- stale client after schema upgrade;
- deletion from one device and edit from another;
- attachment upload interrupted;
- server restore to earlier point while device has later operations;
- account token revoked mid-sync;
- partial projection rebuild.

Assert convergence, no silent loss, and comprehensible conflict output.

## 35.4 Model tests

- schema adherence;
- citation support;
- prompt injection;
- sensitive-data route;
- refusal/fallback;
- deterministic policy gate after stochastic output;
- adversarial user correction;
- stale context;
- contradictory evidence;
- empty data;
- provider outage;
- cost and latency ceilings.

Use frozen model snapshots for reproducibility where providers permit, but expect nondeterminism and set semantic assertions rather than exact strings.

## 35.5 Performance tests

Representative targets:

- 10+ years of daily events;
- millions of health references/features;
- tens of thousands of captures;
- large archive attachment manifest;
- full local projection rebuild;
- search and Now assembly under load;
- battery impact of background sync;
- memory use of map/archive views;
- cold launch after migration.

Do not optimize for hypothetical multi-user scale. Optimize for one very deep history and several devices.

## 35.6 Migration tests

Maintain fixture databases at every released schema. CI upgrades each to head and verifies:

- record counts;
- semantic invariants;
- projection hashes;
- ability to export;
- no orphaned data;
- expected disk growth;
- rollback/read compatibility where declared.

## 35.7 Release qualification

A production build requires:

- all deterministic tests passing;
- migration rehearsal;
- backup confirmed;
- AI regression report;
- permission/entitlement check;
- physical-device smoke test;
- accessibility pass on changed surfaces;
- source/license check for art and research assets;
- feature-flag kill switches;
- release notes including semantic changes;
- explicit owner approval for new authority or data route.

---

# 36. Deployment architecture

## 36.1 Environments

Use:

- **local:** Docker Compose, local SQLite, fake APNs/integrations/models;
- **development:** isolated cloud project, synthetic data, permissive debugging;
- **staging:** production-shaped infrastructure, synthetic or specifically approved copied data, release candidate clients;
- **production:** single owner, strict access, durable backups.

Never point a development build at production by default.

## 36.2 Credential-free implementation

The autonomous implementation agent must be able to build and test without personal credentials through:

- protocol fakes;
- deterministic model stub;
- recorded provider fixtures;
- local OAuth mock;
- synthetic HealthKit adapter;
- local APNs simulator/log;
- MinIO or storage emulator;
- Postgres container;
- queue emulator/in-process worker;
- generated development certificates only where safe.

Every real integration has a handoff checklist rather than hardcoded missing secrets.

## 36.3 Infrastructure provisioning

Infrastructure code provisions:

- projects/accounts prerequisites documented separately;
- network and service access;
- Cloud Run services/workers;
- Cloud SQL instance/database/users;
- storage buckets and lifecycle/versioning;
- queues and service identities;
- Secret Manager entries as placeholders;
- artifact registry;
- monitoring/alerts;
- backup and PITR configuration;
- DNS/custom domain if used;
- budget alerts;
- CI deploy identities via workload identity federation.

Secrets are inserted through documented operator commands or console flow, never Terraform variables committed to state where avoidable.

## 36.4 Backend deployment

Pipeline:

1. lint/type/test;
2. build reproducible container;
3. scan and generate SBOM;
4. push artifact;
5. deploy migration job or verify compatibility;
6. deploy canary/staging;
7. run smoke and contract tests;
8. deploy production with traffic control;
9. monitor SLOs/evals;
10. retain rollback image and compatible schema path.

Database migrations are separate, explicit jobs. Application startup must not perform unbounded production migrations.

## 36.5 Apple release flow

- deterministic Xcode project generation only if the team commits to maintaining it; otherwise keep a reviewed workspace;
- separate bundle identifiers and entitlements by environment;
- automatic signing for development, documented manual/team setup for distribution;
- TestFlight internal cohort for owner devices;
- production App Store/private distribution decision documented after Apple account context is known;
- no dependence on expiring development builds for durable data access;
- export/archive build artifacts and dSYMs;
- capability/entitlement checklist for HealthKit, App Groups, notifications, Sign in with Apple, Background Modes, and associated domains.

## 36.6 Deployment handoff document

The repository must contain `docs/deployment/OWNER_HANDOFF.md` with exact steps:

1. create/choose Apple Developer account and team;
2. create app identifiers and bundle IDs;
3. enable capabilities and containers;
4. create Sign in with Apple configuration;
5. create cloud project and billing budget;
6. enable APIs;
7. provision with infrastructure code;
8. create provider/OAuth applications;
9. set redirect URIs and webhook secrets;
10. add model-provider keys and policies;
11. build and deploy backend;
12. run migrations and seed owner account;
13. configure Xcode signing;
14. install staging app and enroll device;
15. run integration smoke tests;
16. enable production backup/alerts;
17. perform first export and restore drill;
18. promote production build.

Each step includes expected output and troubleshooting.

## 36.7 Rollback

Rollback must cover:

- client feature flag disablement;
- backend image rollback;
- model/prompt rollback;
- integration suspension;
- schema forward fix;
- database point-in-time restore only under incident protocol;
- projection rebuild;
- notification kill switch;
- global proactive-intelligence pause.

A database restore is not a routine application rollback because devices may contain later operations. The incident runbook must reconcile them.

---

# 37. Development-environment recommendation

## 37.1 Hybrid workflow

Use both environments deliberately.

### Bloomberg-managed MacBook

Use for:

- Xcode and Apple SDK compilation;
- iOS/watchOS/iPadOS/macOS simulators;
- physical-device testing;
- HealthKit, EventKit, WidgetKit, App Intents, ActivityKit, WorkoutKit, Core Location;
- signing and entitlement work where permitted;
- performance, battery, accessibility, and UI validation.

### Bloomberg Spaces/container environment

Use for:

- backend and database development;
- data migrations;
- AI orchestration and evaluations;
- evidence pipelines;
- infrastructure code;
- reproducible test suites;
- large synthetic-data generation;
- long-running autonomous implementation;
- documentation and source analysis.

## 37.2 Repository and branch flow

- one portable monorepo;
- no architecture dependency on Bloomberg identity;
- environment-neutral Git configuration;
- short-lived branches or stacked changes;
- required CI checks;
- signed or verified release commits where practical;
- all secrets outside repository;
- exportable patch/bundle mechanism if direct remote access is constrained.

## 37.3 Contract between environments

The container environment must generate artifacts that the Mac can consume:

- OpenAPI and schema packages;
- synthetic fixtures;
- backend containers;
- evaluation reports;
- migration bundles.

The Mac produces:

- client test results;
- UI snapshots;
- device capability reports;
- signed builds;
- Apple integration traces.

A top-level command such as `make verify` runs all environment-available checks and clearly reports skipped Mac-only tests.

## 37.4 Avoiding environment capture

- do not use filesystem paths specific to managed machines;
- use standard containers and lockfiles;
- document tool versions;
- vendor no proprietary Bloomberg library;
- keep cloud and source-control identities configurable;
- ensure a personal Mac can clone, build, and deploy after handoff;
- produce a bill of external accounts and entitlements.

## 37.5 Autonomous-agent working protocol

The implementation agent should:

1. read Constitution and invariants first;
2. maintain an assumptions log;
3. create ADRs for consequential departures;
4. work in vertical, testable slices;
5. keep synthetic data realistic;
6. never reset persistent data to solve a migration problem;
7. generate progress artifacts and runnable demos;
8. run evaluation gates before enabling AI behavior;
9. flag any credential-dependent step with exact handoff instructions;
10. leave the repository buildable after every milestone.

---
# 38. Detailed implementation roadmap

## 38.1 Roadmap philosophy

Build Odyssey in **editions**, each of which is coherent enough to live with and designed to generate evidence for the next edition. Avoid a horizontal “finish all backends, then all screens” plan. Each milestone must deliver a vertical loop from durable input to useful output to evaluation.

The roadmap distinguishes:

- substrate that must be correct before real personal history is entrusted;
- product loops that test the philosophy;
- intelligence that should be added only after data and evaluation exist;
- aesthetic ambition that should amplify a proven model rather than hide an unproven one.

## 38.2 Edition 0 — Durable substrate and executable skeleton

**Objective:** prove that the repository, local data, cloud data, sync, build, test, and recovery paths are trustworthy.

### Milestone 0.1 — Repository and architecture skeleton

Deliver:

- monorepo structure;
- Swift packages and empty platform shells;
- Python modular monolith;
- OpenAPI/code-generation pipeline;
- local Docker Compose;
- CI for backend and available Swift tests;
- ADR template and initial ADRs;
- synthetic-life fixture generator;
- environment diagnostics.

Exit criteria:

- a fresh clone runs backend, database, and synthetic client flow using documented commands;
- no real credentials required;
- schema generation is deterministic.

### Milestone 0.2 — Local ledger and projections

Deliver:

- SQLite schema and migration framework;
- immutable capture/ledger write;
- typed assertions and provenance;
- core entities: Charter, LifeStage, Season, Direction, Commitment, Capture;
- projection rebuild command;
- local export;
- pre-migration backup.

Exit criteria:

- 10-year synthetic dataset imports and queries within performance budget;
- database can be rebuilt from ledger/source records;
- migration from each fixture version passes.

### Milestone 0.3 — Cloud core and sync

Deliver:

- PostgreSQL schema;
- owner bootstrap/auth stub and production design;
- push/pull sync endpoints;
- idempotent operation handling;
- tombstones and domain merge policies;
- attachment upload path;
- sync diagnostics;
- local/cloud conflict tests.

Exit criteria:

- two simulated devices converge through offline conflict scenarios;
- no data loss after injected network failures;
- server projection rebuild works.

### Milestone 0.4 — Durability and observability

Deliver:

- structured logging and traces;
- backup configuration scripts;
- logical export;
- clean-room restore script;
- incident and migration runbooks;
- integrity checks;
- kill switches.

Exit criteria:

- an isolated restore succeeds from documented steps;
- a capture remains recoverable after simulated client reinstall and server outage;
- operator can trace a synthetic record from capture through sync.

**Do not begin real-life dogfooding before Edition 0 exit criteria.**

## 38.3 Edition 1 — Orientation and low-friction foundations

**Objective:** prove Odyssey can make ordinary days clearer without creating a ritual burden.

### Milestone 1.1 — Charter and Season Workshop

Deliver:

- versioned Charter editor;
- current life-stage model;
- season creation/revision/transition;
- portfolio of primary, foundation, maintenance, and dormant directions;
- explicit constraints and “not now” areas;
- season history;
- plain-language and map prototype views.

Seed current season from the commission, but require owner review before treating it as accepted state.

Exit criteria:

- every recommendation can resolve the active Charter/season version for its time;
- old versions are inspectable and immutable;
- user can revise without data reset.

### Milestone 1.2 — Capture and personal library

Deliver:

- universal local capture;
- voice/text ingestion;
- asynchronous interpretation stub/model adapter;
- food presets and frequency/context ranking;
- calories/protein/caffeine/alcohol logging;
- shortcut, widget/control, and Watch quick capture;
- correction workflow;
- HealthKit write adapter behind permission.

Exit criteria:

- a common food can be logged in two or three interactions and under five seconds on a warm path;
- capture never waits for network;
- every interpreted field links to original capture.

### Milestone 1.3 — Apple context adapters

Deliver:

- HealthKit incremental import and source metadata;
- EventKit calendar mirror;
- Weather integration;
- conservative location/place support;
- capability/permission matrix;
- integration health UI;
- synthetic adapters for tests.

Exit criteria:

- denied permissions produce useful degraded behavior;
- duplicate workouts/samples are handled;
- travel/timezone fixture produces correct local-day context.

### Milestone 1.4 — Now and Tomorrow Map v1

Deliver:

- deterministic current-context projection;
- Now states: Clear, Choice, Preparation, Recovery, Open, Disrupted;
- automatically generated Tomorrow Map from known constraints;
- manual correction;
- widget snapshots;
- re-entry mode after absence;
- empty/silent state.

No free-form LLM is required for core correctness. A model may render concise text from a structured state.

Exit criteria:

- historical/synthetic scenarios select coherent states;
- the screen renders from local cache under latency target;
- “nothing requires attention” is represented intentionally.

### Milestone 1.5 — Product telemetry and review

Deliver:

- governed event registry;
- question-driven telemetry for capture and Tomorrow Map;
- usefulness/friction correction controls;
- weekly review artifact;
- feature flags;
- privacy/telemetry controls.

Edition 1 dogfood gate:

- no unresolved P0/P1 durability issue;
- real data export tested;
- notification count defaults to zero until Edition 2 policy is enabled;
- one-week protocol prepared.

## 38.4 Edition 2 — Decision, consequence, and intent loops

**Objective:** prove Odyssey can help at a small number of consequential moments.

### Milestone 2.1 — Decision journal and preparation

Deliver:

- decision entity, options, criteria, reversibility, stakes;
- concise decision card;
- accept/adapt/defer/dismiss;
- outcome-follow-up scheduling;
- retrospective calibration;
- provenance and evidence expansion;
- career opportunity decision template;
- no external side effects.

Exit criteria:

- a decision can be reconstructed from context through outcome;
- revisions are explicit;
- user can see what Odyssey omitted or assumed.

### Milestone 2.2 — Temporal consequence engine v1

Implement deterministic and evidence-backed models for four bounded domains:

1. sleep and next-day/near-term constraints;
2. training and recovery;
3. interview preparation;
4. important relationship commitments.

Deliver:

- dependency graph;
- consequence candidates;
- time horizons;
- accumulation detection;
- counterfactual sensitivity;
- explanation templates;
- confidence/uncertainty;
- replay evaluations.

Do not attempt a universal causal simulator.

### Milestone 2.3 — Intent engine v1

Deliver:

- intent schema;
- opportunity windows;
- context predicates;
- receptivity/burden policy;
- silence gate;
- notification budget;
- local schedule registry;
- server opportunity evaluation;
- client delivery-time recheck;
- Watch/widget ambient alternatives;
- feedback and suppression.

Start with at most four intent classes:

- standardized morning weight opportunity;
- sleep/wind-down stakes;
- planned training opportunity;
- interview preparation window.

Relationships should initially surface only explicit commitments, not inferred contact obligations.

### Milestone 2.4 — AI synthesis with evaluations

Deliver:

- provider registry;
- structured output schemas;
- retrieval pack builder;
- model-run tracing;
- direct API adapter;
- deterministic fallback;
- golden evaluation sets;
- citation/claim checks;
- model/prompt rollout gate.

Exit criteria:

- every recommendation has a structured basis and source links;
- unsupported-claim rate meets threshold;
- provider outage leaves core loops usable.

### Milestone 2.5 — One-month dogfood release

Deliver:

- TestFlight/internal distribution with stable data access;
- one-week and one-month protocols;
- weekly telemetry/evaluation report;
- feedback capture;
- global proactive pause;
- low-demand mode.

## 38.5 Edition 3 — Personal evidence, archive, and domain depth

**Objective:** turn accumulated history into trustworthy learning and retrospective value.

### Milestone 3.1 — Evidence library

Deliver:

- source/claim/appraisal model;
- DOI/PMID metadata ingestion;
- citation spans;
- evidence confidence and applicability;
- claim contradiction links;
- evidence inspection UI;
- research update mechanism;
- health recommendation policy.

### Milestone 3.2 — Personal analytics and N-of-1 laboratory

Deliver:

- comparable-day cohort builder;
- missingness/confound inspection;
- robust descriptive associations;
- hypothesis registry;
- experiment eligibility screen;
- randomized/crossover assignment engine;
- preregistration;
- analysis with uncertainty;
- stop/adverse-event rules;
- result replication state.

Initial safe experiments might cover notification timing, caffeine cutoff, or preparation scheduling—not diagnosis, medication, injury treatment, or consequential relationship behavior.

### Milestone 3.3 — Training and nutrition depth

Deliver:

- 12-week or flexible training blocks;
- rotating primary/maintenance discipline;
- workout scheduling via WorkoutKit where supported;
- plan adherence without punitive scoring;
- load/recovery interpretation;
- food recipe/restaurant presets;
- nutrition completeness/data quality;
- user-controlled adaptation proposals.

All training logic must distinguish plan, actual, modification, and outcome.

### Milestone 3.4 — Archive v1

Deliver:

- episode clustering from events/places/people/photos;
- source-linked episode drafts;
- user edit/accept/reject;
- season/chapter navigation;
- map and timeline;
- “original versus current interpretation” view;
- annual export artifact;
- no fabricated quotes or events.

### Milestone 3.5 — Relationship memory, conservatively

Deliver only after a separate sensitivity review:

- explicit person significance/context;
- commitments and important dates;
- shared experiences;
- preparation cues;
- privacy scopes;
- correction/deletion;
- no ranking or automatic outreach.

## 38.6 Edition 4 — Meta-learning and expressive world

**Objective:** allow Odyssey to improve itself and become a richer long-term object after core trust is earned.

Deliver:

- product-change proposal engine;
- controlled product experiments;
- inference expiry/reconfirmation;
- expanded Archive chapters and eras;
- mature stateful art system;
- advanced iPad/Mac workspaces;
- selected Tier 1 integrations;
- optional bounded research agents;
- model-provider benchmarking automation;
- annual Charter/architecture review.

Do not begin Edition 4 because the roadmap says so. Begin only after Edition 2/3 evidence shows sustained value and manageable friction.

## 38.7 Milestone acceptance artifact

Every milestone ends with:

- runnable build;
- release notes;
- ADRs;
- test/evaluation report;
- known limitations;
- data migration and rollback notes;
- telemetry questions;
- owner-visible demo script;
- next-milestone prerequisites;
- updated risk register.

---

# 39. Dependency graph between major systems

## 39.1 System dependency diagram

```text
Constitution + Charter versions
           |
           v
Life stage + Season portfolio -------> Visual theme state
           |
           v
Canonical entity/temporal model <----- Integration adapters
           |                                  |
           v                                  v
Local ledger + projections <------ Health/Calendar/Location/Weather
           |
           +----> Local Now/Tomorrow projections
           |
           +----> Operation log ----> Sync service ----> Cloud ledger/Postgres
                                                     |
                                                     +--> Derived features
                                                     +--> Evidence store
                                                     +--> Semantic edges/search
                                                     +--> Archive synthesis
                                                     +--> AI retrieval packs
                                                                  |
                                                                  v
                         Decision architecture <--- AI/rule synthesis
                                  |                       |
                                  v                       v
                         Consequence engine ------> Intent opportunity engine
                                                           |
                                                           v
                                                    Policy/silence gate
                                                           |
                           +-------------------------------+------------------+
                           v                               v                  v
                     In-app surface                  Ambient surface     Notification/alarm
                           |                               |                  |
                           +-------------------------------+------------------+
                                                           v
                                                   User action/outcome
                                                           |
                                                           v
                                         Personal learning + product telemetry
                                                           |
                                  +------------------------+------------------+
                                  v                                           v
                         Model/preferences update                    Product-change proposal
```

## 39.2 Critical path

The minimum critical path is:

1. temporal/provenance schema;
2. durable local write;
3. migration/backup;
4. sync;
5. Charter/season;
6. deterministic context projection;
7. capture and Apple adapters;
8. evaluation/telemetry;
9. bounded decision/consequence logic;
10. intent policy;
11. model synthesis;
12. Archive/meta-learning.

AI does not precede trustworthy state. Art does not precede coherent orientation. Notifications do not precede a silence policy.

## 39.3 Dependency rules

- `Archive` may read all accepted/observed data but cannot mutate canonical events.
- `AI` cannot query storage directly; it uses authorized retrieval tools.
- `Intent` consumes structured consequences and context, not arbitrary prose.
- `Notifications` cannot generate new recommendations; they deliver approved intervention objects.
- `Scores` consume versioned state and never alter Charter/season.
- `ProductTelemetry` references product events and outcome links but cannot silently rewrite personal preferences.
- `Integrations` write source records and normalized observations, not high-level truths.
- `VisualThemeResolver` consumes season/state tokens but cannot change navigation or policy.

## 39.4 Parallelizable work

After Edition 0 schema contracts stabilize, these can proceed in parallel:

- Apple adapters;
- Now/Map visual prototype;
- backend sync and jobs;
- synthetic fixtures and evaluations;
- evidence ingestion spike;
- deployment/infrastructure;
- Watch/widget shells.

These should not proceed independently:

- sync conflict semantics and local data model;
- AI output schemas and decision entities;
- notification implementation and intent policy;
- score UI and score philosophy;
- relationship features and sensitivity model.

---

# 40. What should be built first and why

## 40.1 First: durable capture and temporal truth

Without durable, provenance-rich data, every later intelligence feature is theatre. The first production-quality capability should be a capture that survives reinstall, migration, offline use, and provider failure.

## 40.2 Second: Charter and season model

Odyssey cannot know relevance without a versioned account of what matters now. This model is the constraint system for all later recommendations and scores.

## 40.3 Third: current-context projection

A deterministic local context combining calendar, HealthKit, plan, recent activity, and season should exist before an LLM explains it.

## 40.4 Fourth: five high-value loops

Prioritize:

1. **Tomorrow clarity** — automatically expose the shape of tomorrow;
2. **nutrition capture** — personal history makes repeated logging fast;
3. **training block** — plan/actual/adaptation across running and strength;
4. **career next action** — prepare exceptional opportunities, not application volume;
5. **bounded sleep stakes** — connect tonight with real future commitments.

These loops cover orientation, friction reduction, cross-domain consequence, Apple integration, and personal learning without requiring the entire ontology.

## 40.5 Fifth: telemetry and replay from day one

The unusual edition cycle makes instrumentation part of product development, not post-launch analytics. Historical replay should exist before proactive recommendations are trusted.

## 40.6 Why not start with the archive or map

The map and archive are emotionally central but depend on accurate entities, time, provenance, and accepted interpretations. Prototype their language early, but do not make them the foundational storage model.

## 40.7 Why not start with a chatbot

A chatbot can demo broad capability while hiding missing state, provenance, and action contracts. Odyssey should first make high-value moments work without conversation; conversation can then query and compose those systems.

---

# 41. What should deliberately be deferred and why

## 41.1 Universal life score

Deferred indefinitely because it collapses plural values, invites Goodhart effects, and creates false authority.

## 41.2 Elaborate 3D or game world

Deferred until the 2D information model survives sustained use. It has high implementation and novelty risk and does not resolve core decision quality.

## 41.3 Continuous high-resolution location history

Deferred until a concrete archive/decision question demonstrates value beyond visits/significant changes. It carries battery, semantic, and exposure costs.

## 41.4 Broad email ingestion

Deferred because inbox access is exceptionally sensitive and creates prompt-injection, parsing, and attention risks. Begin with explicit share/import or narrowly scoped itinerary/job capture.

## 41.5 Financial aggregation

Deferred until there is a specific decision loop such as runway for a job transition or travel budget. Do not collect transactions merely to have them.

## 41.6 Automated job applications and external communication

Deferred because quality, authenticity, terms, and irreversible external effects dominate convenience. Odyssey may prepare drafts and checklists; submission remains explicit.

## 41.7 Dating-app integration or romantic ranking

Deliberately not built. It conflicts with the stated outcome, depends on unsupported/brittle access, and risks instrumentalizing people.

## 41.8 Generalized multi-agent framework

Deferred because core workflows need predictable state and permission control, not autonomous organizational theatre.

## 41.9 Dedicated graph, vector, search, and event-store services

Deferred until Postgres/SQLite measurements prove a need. Each service adds backup, migration, authorization, and failure modes.

## 41.10 Clinical recommendations

Odyssey may support general wellbeing and user-led tracking, but diagnosis, treatment changes, medication management, eating-disorder-sensitive behavior, injury rehabilitation, and acute mental-health intervention require separate clinical governance and should not emerge accidentally from general recommendation code.

## 41.11 Social comparison and public sharing

Not part of the product. Sharing an archive artifact or plan can be explicit, but no leaderboards, feed, or comparison norms.

## 41.12 Generative daily journaling

Deferred as a default. The archive should emerge from living and concise corrections; do not manufacture a mandatory reflective ritual.

---

# 42. Explicit open questions

These questions should be resolved through owner decisions, technical spikes, or real use—not hidden assumptions.

## 42.1 Product and philosophy

1. Which Charter commitments are truly enduring, and which are current-season language?
2. Should Odyssey ever recommend reducing a stated priority when behavior and wellbeing consistently conflict with it?
3. How should “open time” be protected and represented?
4. What information about romantic exploration feels supportive rather than clinical?
5. What does the user want Odyssey to forget, even when storage is possible?
6. How much aesthetic ceremony is welcome around season changes?
7. Is a concise daily alignment indicator motivating or oppressive after two weeks?
8. Should “career acceleration” include Bloomberg work performance and external exploration in one path or two coordinated paths?
9. What counts as a meaningful relationship contact for different people?
10. Which life events should never be auto-summarized?

## 42.2 Data and privacy

11. Should highly sensitive reflections be local-only, end-to-end encrypted, or cloud-readable for AI?
12. Is broad calendar read access acceptable after a feature demonstration?
13. Is visit-level location history worth retaining, and for how long at raw precision?
14. Should Photos metadata be indexed locally only?
15. Which model providers/data-retention settings are acceptable for health and relationship context?
16. What is the desired recovery trade-off for client-side encryption?
17. Should product telemetry remain local until review, or sync automatically?

## 42.3 Apple/platform

18. Which owned devices and minimum OS versions must be supported at first release?
19. Is distribution through TestFlight sufficient, or is private/public App Store durability required?
20. Which iOS 27 capabilities remain valuable after they are stable, and what are their device constraints?
21. How reliably do relevant HealthKit sources deliver sleep/workout data on the actual devices?
22. Does WorkoutKit express the required running and strength sessions adequately?
23. Which Watch complication/widget provides repeated value rather than novelty?

## 42.4 Backend and AI

24. Which cloud account can be owned independently of Bloomberg?
25. Which primary and fallback model providers win task-specific evaluations at implementation time?
26. Is a durable workflow engine needed after the first long-running research jobs are implemented?
27. How much raw model input/output should be retained for debugging?
28. What monthly model/infrastructure budget is appropriate?
29. Should evidence ingestion use only user-added sources initially or include curated automated updates?
30. When does MCP provide genuine connector reuse versus unnecessary attack surface?

## 42.5 Evidence and learning

31. Which recommendations require medical/expert review before activation?
32. What minimum sample sizes and stability rules should exploratory personal patterns use?
33. Which N-of-1 experiments are acceptable and worthwhile?
34. How should multiple testing be controlled in broad personal analytics?
35. What degree of evidence detail is useful in the default interface?
36. How should conflicting personal and population evidence be presented?

## 42.6 Operations

37. Who can access production infrastructure and under what emergency procedure?
38. What backup retention and geographic redundancy match the value of the archive?
39. How will ownership migrate off managed development accounts?
40. What is the acceptable operational maintenance per month?

---

# 43. Experiments requiring real-world usage

## 43.1 Experiment governance

Each experiment requires:

- hypothesis;
- affected surface/data;
- expected benefit;
- plausible harm;
- primary and guardrail outcomes;
- duration or sample target;
- analysis method;
- stop condition;
- reversal plan;
- owner consent where behavior is manipulated.

## 43.2 Tomorrow Map value

**Hypothesis:** an automatically generated map viewed on relevant evenings/mornings reduces planning uncertainty and increases follow-through without becoming a ritual burden.

**Design:** two-week baseline, then alternating availability or randomized prompt/no-prompt on eligible days. The map itself can remain available; randomize proactive surfacing.

**Primary:** self-reported clarity sampled at most several times per week; next-day plan correction burden.

**Guardrails:** time spent configuring, annoyance, reduced spontaneity.

## 43.3 Proactive sleep-stakes cue

**Hypothesis:** a context-specific consequence cue is more useful than a fixed bedtime reminder.

**Eligible points:** nights with detectable medium stakes and no conflicting social/travel exception.

**Conditions:** context cue versus no visible cue; never intentionally withhold safety-critical information.

**Outcomes:** wind-down initiation, sleep opportunity, next-day regret/usefulness, dismissal.

**Caveat:** observational HealthKit sleep timing is noisy and effects are confounded.

## 43.4 Caffeine cutoff personal experiment

**Hypothesis:** caffeine after a candidate cutoff worsens sleep onset/duration for this user.

**Prerequisites:** stable caffeine logging, sufficient baseline, no medical contraindication, manageable intake, washout/carryover assumptions.

**Design:** randomized eligible days across two safe cutoff policies; preregister outcome and confound collection.

**Guardrails:** no forced caffeine consumption; only restriction timing; terminate if daily functioning worsens materially.

## 43.5 Food preset ranking

**Hypothesis:** context-aware top presets reduce logging time and abandonment versus frequency-only ranking.

**Design:** randomize ranking algorithm at capture opportunities.

**Outcomes:** time to durable log, correction rate, abandonment, wrong-selection reversals.

## 43.6 Interview preparation opportunity

**Hypothesis:** surfacing a specific prepared exercise in a naturally open window increases high-quality preparation more than a generic reminder.

**Design:** compare specific action cue, ambient-only state, and no cue over repeated eligible windows.

**Outcomes:** preparation started/completed, quality rating, interruption cost, displaced commitments.

## 43.7 Score visibility

**Hypothesis:** a quiet weekly alignment explanation motivates reflection without daily pressure.

**Design:** score-free baseline, qualitative weekly state, optional numeric weekly score. Do not introduce a daily score first.

**Guardrails:** anxiety, gaming, logging distortion, negative reaction to legitimate exceptions.

**Removal rule:** any persistent pressure or optimization distortion without clear decision value.

## 43.8 Widget utility

**Hypothesis:** Current Thread or Training widget reduces app-opening burden and supports action.

**Design:** rotate widget content by week, measure glance proxy only where platform data permits, action deep links, and qualitative recall.

**Caveat:** Apple does not expose a perfect “widget consulted” measure; avoid false attribution.

## 43.9 Archive episode suggestions

**Hypothesis:** source-linked episode drafts create retrospective value with low correction burden.

**Design:** compare event clustering methods on past months; user blind-rates factual accuracy, emotional resonance, omissions, and editing effort.

**Guardrails:** fabricated significance, inappropriate resurfacing, sensitive-person exposure.

## 43.10 Re-entry mode

**Hypothesis:** after three or more days away, a clean summary with one question is more effective than accumulated cards.

**Design:** simulate/replay and then use on natural absences; compare time to useful state and frustration.

## 43.11 Stateful art intensity

**Hypothesis:** subtle season-responsive art improves orientation and attachment without reducing speed or clarity.

**Design:** calm tokens-only theme versus richer 2D map atmosphere across multi-week periods.

**Outcomes:** preference, comprehension, task time, reduced-motion use, novelty decay.

---

# 44. One-week evaluation protocol

## 44.1 Purpose

The first week is a **friction and trust audit**, not a verdict on long-term behavior change. A week is sufficient to expose obvious latency, capture burden, permission, notification, and interpretation failures; it is not sufficient to infer stable personal effects.

## 44.2 Before the week

- confirm backup and export;
- record build, schema, model, prompt, and feature-flag versions;
- verify all enabled integrations and permissions;
- choose no more than three proactive intervention classes;
- document expected daily use, but do not demand it;
- capture a short baseline interview: current priorities, concerns, and what would feel intrusive;
- mark known unusual events such as travel, race, interview, illness, or social commitments;
- enable a one-tap global pause.

## 44.3 Daily passive collection

Collect:

- app and surface interactions;
- capture duration and abandonment;
- sync/background errors;
- recommendation presentation and response;
- notification delivery/interaction;
- correction type;
- model and retrieval trace;
- relevant outcome signals;
- device/permission availability;
- no more personal data than the feature contract already requires.

## 44.4 Daily micro-check

At most once per day, and skippable:

1. Did Odyssey help at any moment today? Which?
2. Did it get in the way or make you feel monitored?
3. Was anything important wrong?

Use a 10–20 second interaction plus optional voice note. Do not ask for a full diary.

## 44.5 Immediate incident triggers

Pause the affected capability if any occurs:

- data loss or duplication with user impact;
- sensitive lock-screen exposure;
- unauthorized external action;
- dangerous health recommendation;
- repeated notification after dismissal;
- confident fabricated personal fact;
- recommendation using excluded data;
- migration or sync corruption;
- severe performance/battery regression.

## 44.6 Midweek review

After roughly three or four days, inspect only severe friction:

- top abandoned workflows;
- repeated factual corrections;
- notification annoyance;
- integration failures;
- latency;
- obvious missing quick presets;
- unexpected emotional reaction.

Apply only reversible bug fixes or suppressions. Do not redesign the whole product midweek; preserve enough consistency to evaluate.

## 44.7 End-of-week interview

Use concrete event replay rather than abstract satisfaction questions:

- Show the five most consequential Odyssey interactions.
- For each: What was happening? Was the context right? Did it change anything? What would have been better—different advice or silence?
- Review three ignored/dismissed interventions.
- Review capture sessions with highest friction.
- Inspect one AI reasoning trace and one evidence expansion.
- Ask what the user avoided recording and why.
- Ask whether any day felt over-optimized.
- Ask what the user would miss if Odyssey disappeared tomorrow.

## 44.8 Week-one report

Produce:

- data integrity and reliability status;
- friction map by workflow;
- recommendation correctness examples;
- intervention precision and burden;
- top corrections;
- permission/integration gaps;
- unexpected behavior;
- proposed bug fixes;
- product hypotheses, clearly separated from conclusions;
- capabilities to disable, preserve, or investigate;
- no more than five recommended next changes.

## 44.9 Week-one decision gate

Proceed to broader use only if:

- no unresolved critical durability/security issue;
- core capture is fast enough;
- the user understands why key recommendations appeared;
- notification burden is acceptable;
- a reliable export exists;
- model errors are recoverable and visible;
- at least one loop delivered credible value.

---

# 45. One-month evaluation protocol

## 45.1 Purpose

One month can reveal habit compatibility, season fit, repeated intervention effects, stale inference, novelty decay, and whether the system saves cognitive work. It still cannot prove many long-term health or life outcomes.

## 45.2 Freeze and annotation

Before analysis:

- freeze a data snapshot and configuration manifest;
- annotate travel, illness, deadlines, major social events, interviews, and device/integration outages;
- identify feature-rollout dates;
- note incomplete data periods;
- preserve original model outputs and later corrections.

## 45.3 Quantitative review

### Reliability

- crashes/hangs;
- sync convergence and conflicts;
- backup/restore status;
- integration lag;
- widget/background freshness;
- AI schema failure and fallback;
- battery/performance reports.

### Friction

- median/p95 capture time by type;
- abandonment by step and context;
- number of manual fields later unused;
- repeated manual work candidates;
- time spent configuring versus acting.

### Interventions

- eligible opportunities;
- silence/suppression rate;
- visible interruptions;
- useful action, dismissal, correction, and regret;
- bad timing;
- repeated content;
- outcomes by intervention class where estimable.

### Decision support

- decisions prepared;
- recommendation accepted/adapted/rejected;
- later outcome and confidence calibration;
- omitted considerations discovered;
- decisions where Odyssey should have remained silent.

### Personal informatics

- data completeness where needed;
- number of patterns surfaced;
- number that survived review;
- hypotheses promoted to experiments;
- false/unstable insights;
- evidence inspections.

### Archive

- episodes suggested;
- factual correction burden;
- archive revisits;
- moments considered meaningful;
- sensitive or unwanted resurfacing.

## 45.4 Qualitative review

Interview themes:

- What did Odyssey make easier?
- What became another obligation?
- When did it understand the real situation?
- When did it expose a useful truth?
- When was its knowledge creepy or irrelevant?
- Did it preserve open and spontaneous time?
- Did scores or tracking change behavior undesirably?
- Which surface fit naturally: iPhone, Watch, widget, Mac?
- Which recommendation earned trust? Which spent it?
- What has changed in the season or Charter?
- What should Odyssey know less about?
- Which feature should disappear entirely?

Use event and trace examples to reduce hindsight generalization.

## 45.5 North Star assessment

Rate the product on a 1–5 rubric with evidence:

- orientation quality;
- decision usefulness;
- friction reduction;
- scientific honesty;
- personal-learning restraint;
- agency and trust;
- relationship sensitivity;
- silence quality;
- technical reliability;
- archive emergence;
- visual comprehension;
- adaptability.

Do not average into one headline number without retaining dimensions and comments.

## 45.6 Counterfactual audit

Select at least five days and ask:

- What would likely have happened without Odyssey?
- Did Odyssey cause action, merely accompany it, or add burden?
- Which data was actually needed?
- Could a simpler deterministic feature have delivered the same value?
- Did an intervention crowd out something better?

## 45.7 Architecture audit

Review:

- unused abstractions;
- query/performance hotspots;
- schema pain;
- provider lock-in;
- integration maintenance cost;
- migration/backup confidence;
- model evaluation gaps;
- local/cloud boundary;
- observability blind spots;
- security/data-route changes.

## 45.8 One-month output

Produce a versioned **Edition Evidence Pack**:

1. executive findings;
2. product North Star assessment;
3. reliability and durability report;
4. high-value moments;
5. severe failure cases;
6. friction and abandonment analysis;
7. intervention evaluation;
8. AI/evidence evaluation;
9. personal-learning review;
10. visual and surface review;
11. current Charter/season changes;
12. proposed product changes with evidence;
13. architecture changes;
14. features to remove/defer;
15. next-edition experiment plan;
16. frozen traces/datasets for regression.

## 45.9 Month-one decision categories

Every feature is assigned:

- **Keep unchanged** — demonstrated value and no material harm;
- **Refine** — value exists, friction/error is addressable;
- **Experiment** — plausible but inconclusive;
- **Dormant** — not relevant in current season;
- **Remove** — cost/harm exceeds value;
- **Architectural rewrite** — concept valuable, implementation untrustworthy.

---

# 46. Instructions for the next major development iteration

## 46.1 Input contract

The next implementation run receives:

- this specification and later amendments;
- Edition Evidence Pack;
- accepted/rejected product-change proposals;
- current Charter and season versions;
- issue and incident register;
- frozen evaluation cases;
- telemetry schema and derived reports;
- current architecture and ADRs;
- migration history;
- provider/integration status;
- owner’s explicit priorities and non-goals.

## 46.2 Required first phase

Before writing code, the agent must:

1. compare real evidence to the original hypotheses;
2. identify assumptions falsified by use;
3. classify requested changes as bug, workflow, model, policy, schema, or aesthetic;
4. assess data migration and backward compatibility;
5. update threat model and evaluation plan;
6. propose a bounded edition scope;
7. record ADRs for architecture departures.

Do not preserve a feature merely because it was expensive to build.

## 46.3 Evidence hierarchy for iteration decisions

Use, in order:

1. safety and data-integrity incidents;
2. repeated concrete user experience and correction;
3. observed workflow outcomes with context;
4. controlled product experiments;
5. stable telemetry patterns;
6. research and engineering evidence;
7. original design preference;
8. implementation convenience.

One vivid complaint can outrank aggregate telemetry when it reveals a severe boundary violation. Conversely, one delightful anecdote does not prove a feature broadly useful.

## 46.4 Change-plan format

For each proposed change specify:

- evidence;
- target problem;
- invariant affected;
- data/schema impact;
- UX behavior;
- model/policy impact;
- migration;
- telemetry and evaluation;
- rollback;
- dependencies;
- explicit non-goals.

## 46.5 Regression preservation

Every major real-world failure becomes:

- a synthetic or frozen replay case;
- a deterministic test if possible;
- an AI evaluation case where relevant;
- a monitoring signal;
- a release-note item when behavior changes.

## 46.6 Scope control

The next edition should have:

- no more than three top-level product hypotheses;
- one data/durability objective;
- one intelligence-quality objective;
- one experience/art objective;
- explicit removals;
- a real-use evaluation window.

A large compute budget is not permission to expand every subsystem simultaneously.

## 46.7 Owner approvals required

Explicit approval is required before:

- new sensitive data source;
- broader model-provider data route;
- external side-effect authority;
- relationship inference change;
- new score visible to the user;
- continuous location mode;
- destructive migration;
- major Charter/season semantic change;
- public or third-party data sharing;
- clinical/high-stakes recommendation class.

---

# 47. Comprehensive implementation-agent handoff

## 47.1 Mission

Build a private, Apple-native, local-first personal navigation system for one owner. Its purpose is to improve orientation and judgment in a changing life, reduce the friction of worthwhile action, learn honestly from population and personal evidence, and preserve a durable history without turning life into a productivity contest.

## 47.2 Non-negotiable invariants

1. No real personal history is disposable.
2. Local capture and core state do not depend on network or LLM availability.
3. Every consequential fact and recommendation has provenance.
4. Charter, life stage, and season are versioned.
5. Decisions are central but not the ontology root.
6. AI cannot own canonical state, permissions, or irreversible actions.
7. No universal Life Score.
8. Silence is a valid and often preferred intervention result.
9. Relationships are not ranked or reduced to engagement metrics.
10. Every external action obeys authority and confirmation policy.
11. Every model/provider change is evaluated and reversible.
12. Apple background APIs are treated as best effort unless official semantics say otherwise.
13. The graph, vector index, and summaries are derived, rebuildable structures.
14. User correction changes durable semantics, not only analytics.
15. The system must export and restore without proprietary manual reconstruction.

## 47.3 Preferred architecture

- Swift/SwiftUI native clients;
- SQLite/GRDB local operational database;
- append-only fact/event ledger plus relational projections;
- local operation-log sync;
- Python/FastAPI modular monolith;
- PostgreSQL + pgvector;
- object storage;
- transactional outbox and idempotent task workers;
- Google Cloud reference deployment, portable through containers/IaC;
- OpenTelemetry;
- provider-neutral capability registry;
- direct model APIs for core loops, optional SDK for bounded long workflows;
- structured-first retrieval and structured model output.

Departures require ADR and equivalent reliability/evaluation.

## 47.4 Implementation order

1. repository, schemas, synthetic fixtures;
2. local ledger, migrations, backup/export;
3. cloud database, auth, sync, restore;
4. Charter/life stage/season;
5. capture and personal food library;
6. Apple context adapters;
7. deterministic Now/Tomorrow;
8. telemetry/evaluation;
9. decision journal;
10. consequence engine;
11. intent/silence/delivery policy;
12. AI synthesis;
13. evidence and N-of-1;
14. archive and richer art;
15. self-improvement proposals and selected integrations.

## 47.5 Definition of “implementation-ready” for a feature

A feature specification is complete only when it has:

- owner problem and expected decision value;
- domain entities and temporal semantics;
- source-of-truth declaration;
- local/offline behavior;
- sync and conflict behavior;
- permission and authority level;
- UI on each relevant surface;
- empty/error/stale states;
- telemetry question;
- tests and evaluations;
- migration and deletion behavior;
- rollout/kill switch;
- accessibility;
- security/data classification;
- explicit non-goals.

## 47.6 Coding standards

- strict concurrency checking in Swift;
- explicit `Sendable` and actor boundaries;
- no synchronous network or database work on main thread;
- typed IDs and units;
- no raw stringly-typed predicates in product code without registry;
- UTC instants plus original timezone semantics;
- SQL migrations reviewed and tested;
- Python type checking and linting;
- Pydantic schemas at boundaries;
- idempotency for every worker and external mutation;
- structured errors with user-safe mapping;
- no secrets or real personal data in fixtures/logs;
- comments explain invariants and trade-offs, not obvious syntax.

## 47.7 Product language standards

- concise, specific, and autonomy-supportive;
- distinguish observation, inference, and recommendation;
- never claim a causal personal effect without experimental basis;
- do not shame, infantilize, or praise ordinary compliance excessively;
- use “may,” “appears,” and confidence explanations honestly, not defensively;
- say “I don’t have enough evidence” when true;
- name actual consequence and suggested action;
- avoid generic wellness copy.

## 47.8 AI development standards

- define output schema and evaluation before prompt tuning;
- retrieve minimal authorized context;
- cite every factual scientific/personal claim;
- model untrusted-source boundaries;
- run prompt-injection tests;
- log versions and outcome linkage;
- provide deterministic or explicit unavailable fallback;
- do not use model self-confidence as calibrated probability;
- do not let an evaluator model certify its own unsupported source claim;
- cap autonomy at tool-policy layer.

## 47.9 Data development standards

- preserve original payload and content hash;
- never mutate source observations to fit a new model;
- use explicit units and precision;
- store missing versus zero distinctly;
- version semantic interpretation;
- maintain import batch reversibility;
- mark stale derived state;
- test projection rebuild;
- design deletion before ingestion goes live;
- document data lineage.

## 47.10 UX development standards

- Now displays at most a few consequential objects;
- every surface has a useful quiet state;
- capture commits immediately;
- progressive disclosure for evidence;
- no metaphor in safety, permission, or destructive flows;
- all animations communicate state and support reduced motion;
- Dynamic Type and VoiceOver are tested, not assumed;
- Watch interactions should normally finish in seconds;
- widgets are tolerant of staleness;
- configuration lives in Workshop, not daily flow.

## 47.11 Required artifacts at handoff

The implementation run must leave:

- runnable clients and backend;
- source and lockfiles;
- complete migrations;
- synthetic seed data;
- OpenAPI and generated clients;
- infrastructure code;
- account/credential setup instructions;
- deployment and rollback runbooks;
- backup and restore report;
- integration setup guides;
- test and evaluation reports;
- threat model;
- data dictionary and provenance model;
- architecture diagrams and ADRs;
- release notes;
- owner onboarding and Trust Center guide;
- known limitations and deferred work;
- one-week/month evaluation templates.

## 47.12 Conditions for refusing a local implementation shortcut

The agent should not take a shortcut that:

- requires wiping data;
- obscures provenance;
- makes an LLM output canonical without validation;
- assumes background execution timing Apple does not guarantee;
- stores credentials insecurely;
- adds a third-party service without export/exit path;
- bypasses authority confirmation;
- invents scientific certainty;
- turns a relationship into a score;
- creates an untested migration.

## 47.13 Areas where engineering judgment is welcome

- exact Swift state-management pattern;
- visual implementation technology after prototypes;
- Python internal package layout;
- Terraform versus OpenTofu;
- cloud monitoring exporter;
- specific model selection after evaluations;
- whether a durable workflow engine becomes justified;
- index/partition tuning;
- exact Map navigation controls;
- which Tier 1 integration follows real-use demand.

## 47.14 First autonomous-run acceptance test

A successful first major run should demonstrate this scenario end to end:

1. owner installs on a fresh iPhone;
2. accepts/edits a seeded Charter and current season;
3. grants limited HealthKit and calendar access;
4. logs a common meal offline using a preset;
5. the record writes to HealthKit where approved and syncs later;
6. Tomorrow Map detects an interview preparation need and planned training session;
7. a medium-stakes sleep consequence is computed from structured context;
8. the intent policy decides whether to remain silent or surface it;
9. owner inspects why, corrects one assumption, and adapts the action;
10. the correction updates durable state;
11. a second device receives the history;
12. the full chain is visible in provenance/trace;
13. data is exported;
14. a clean-room restore reconstructs it.

The UI may be visually incomplete, but this vertical slice must be technically trustworthy.

---

# 48. Scenario stress tests

Each scenario below is a required design/evaluation case. The expected response is intentionally not a fixed recommendation; it is a set of behaviors and constraints.

## 48.1 Ordinary Bloomberg workday

Context: normal sleep, work commitments, planned easy run, no urgent external interview.

Expected:

- Now is calm and compact;
- no generic productivity checklist;
- work event details do not leak to lock screen;
- run is one available thread, not a moral obligation;
- ordinary food/caffeine capture is fast;
- zero notifications is acceptable.

## 48.2 Interview tomorrow

Context: high-value interview, preparation gaps, calendar constraints, planned hard workout.

Expected:

- surface preparation dependency and opportunity cost;
- compare adapting workout versus reducing sleep;
- present high-confidence known facts and uncertain performance effects separately;
- offer a specific prepared next action;
- never submit or message externally;
- tomorrow’s interview becomes a landmark, not a panic score.

## 48.3 Poor sleep

Context: one poor night after a social event.

Expected:

- no catastrophizing or score punishment;
- distinguish one-off from accumulated debt;
- adapt training recommendation based on actual session and symptoms;
- protect necessary work and allow recovery;
- do not diagnose.

## 48.4 Race in two weeks

Context: sub-20-minute 5K attempt approaching, training block taper, social invitation.

Expected:

- show real stakes without treating race as the whole life;
- recognize taper plan and sleep/recovery dependencies;
- include social value in trade-off;
- avoid introducing untested training changes;
- link to evidence and personal response history.

## 48.5 Holiday and Christmas with family

Expected:

- season/day definition changes;
- normal career/training execution score is suppressed;
- family presence and recovery may define alignment;
- only hard commitments or user-chosen maintenance appear;
- no guilt over logging gaps.

## 48.6 First date

Expected:

- preparation may include logistics, stated preferences, and being present;
- no compatibility score or post-date interrogation;
- relationship data remains private and minimally exposed;
- optional short personal reflection later, never mandatory;
- system remains silent during the date.

## 48.7 Close friend’s birthday

Expected:

- explicit commitment and relationship significance can elevate it;
- remind/prep at an appropriate opportunity, not based solely on message inactivity;
- never send a message without approval;
- shared memory cues are optional and sensitive.

## 48.8 Long-haul flight

Expected:

- timezone-aware calendar and sleep reasoning;
- offline access;
- hydration/movement suggestions only if useful and evidence-appropriate;
- travel day is not judged against normal routines;
- local-day boundaries and HealthKit data do not double count.

## 48.9 Injury

Expected:

- suppress ordinary training progression;
- distinguish symptom observation from diagnosis;
- advise professional assessment when red flags/persistence meet conservative policy;
- no self-experiment that risks harm;
- adjust season temporarily without rewriting identity.

## 48.10 Job offer

Expected:

- create a high-stakes decision with compensation, role quality, growth, people, location, risk, values, and reversibility;
- include source documents and explicit uncertainties;
- generate counterarguments and information requests;
- preserve emotional response as context, not noise;
- no acceptance or negotiation message without explicit approval.

## 48.11 Relationship beginning

Expected:

- allow season allocation to change;
- do not optimize contact frequency or infer attachment from messages;
- protect privacy and presence;
- suggest reviewing commitments if genuine conflicts arise;
- archive shared experiences only through acceptable sources.

## 48.12 Relationship ending

Expected:

- enter low-demand/emotional-safety mode if requested;
- suppress romantic opportunity and “relationship maintenance” prompts;
- avoid resurfacing photos/episodes unexpectedly;
- offer data visibility controls;
- no pseudo-therapy or diagnosis;
- preserve history without forcing interpretation.

## 48.13 Month of travel

Expected:

- season transition or temporary travel context;
- reduce maintenance demands;
- map places/experiences naturally;
- offline-first operation and delayed sync;
- flexible training and nutrition expectations;
- preserve adventure and unplanned days.

## 48.14 User ignores Odyssey for five days

Expected:

- no pile of overdue cards;
- expire stale opportunities;
- summarize only material changes;
- ask at most one high-value question;
- no guilt or streak loss;
- offer clean re-entry or continued quiet.

## 48.15 Dramatic priority change

Context: family need, health event, layoff, new relationship, or changed aspiration.

Expected:

- allow immediate temporary override before a formal Charter review;
- suspend obsolete interventions;
- version season rather than rewriting historical goals;
- conservative calibration period;
- mark old models/preferences as potentially stale.

## 48.16 Wonderful spontaneous evening

Expected:

- do not frame missed planned work as failure automatically;
- capture can be delayed or absent;
- later recognize the experience if sources support it;
- update tomorrow’s constraints honestly;
- preserve the principle that inefficiency can be worthwhile.

## 48.17 Provider outage

Expected:

- local capture and cached Now work;
- model-dependent synthesis says unavailable or uses safe fallback;
- no repeated retries draining battery;
- queued operations remain durable;
- diagnostics identify provider, not generic “something went wrong.”

## 48.18 Conflicting personal and population evidence

Example: population evidence favors an earlier caffeine cutoff; personal observational data shows no stable relationship.

Expected:

- show evidence layers separately;
- do not declare personal immunity;
- identify data quality and plausible confounding;
- propose a safe experiment only if worthwhile;
- permit preference-based decision.

## 48.19 Two devices make conflicting season edits

Expected:

- neither version silently wins;
- show semantic conflict and provenance;
- allow resolution into a new version;
- downstream recommendations reference the accepted version only;
- preserve both edits for audit.

## 48.20 User asks Odyssey to “decide everything today”

Expected:

- provide a prepared plan and identify trade-offs;
- retain user authority over meaningful commitments;
- avoid pretending certainty;
- allow one-tap acceptance of low-risk blocks;
- require confirmation for external or irreversible actions;
- explain that the plan is a proposal, not a command.

---
# Appendix A. Core domain contracts

These contracts are conceptual and should be expressed as versioned JSON Schema/OpenAPI types plus equivalent Swift/Python domain types. Database schemas may normalize them further. Fields marked optional are optional because the concept may genuinely be unknown—not because implementations may ignore them.

## A.1 Common metadata

```text
EntityMetadata
  id: UUIDv7
  schema_version: integer
  created_at: Instant
  created_by: ActorRef
  last_revised_at: Instant
  revision: integer
  tombstoned_at: Instant?
  sensitivity: DataClass
  provenance_id: UUID
```

```text
TemporalInterval
  start: InstantOrLocalDate?
  end: InstantOrLocalDate?
  timezone_id: IANAZone?
  start_precision: exact | minute | hour | day | month | approximate | unknown
  end_precision: same
  all_day_semantics: boolean
```

```text
EpistemicState
  kind: observed | user_stated | externally_asserted | inferred | hypothesized |
        experimentally_supported | accepted_interpretation | retracted
  confidence_band: very_low | low | moderate | high | very_high?
  numeric_confidence: decimal?       // internal/calibrated only
  applicability: direct | partial | indirect | unknown
  last_evaluated_at: Instant?
  expires_at: Instant?
```

## A.2 Charter and season

```text
CharterVersion
  metadata
  charter_id
  version_number
  effective_interval
  values[]:
    id
    title
    description
    positive_expression
    anti_value_or_failure_mode?
  responsibilities[]
  desired_ways_of_being[]
  non_negotiable_boundaries[]
  anti_optimization_statements[]
  interpretation_notes
  supersedes_version_id?
  accepted_at
```

```text
LifeStageVersion
  metadata
  stage_id
  effective_interval
  title
  career_context
  partnership_family_context
  health_capability_context
  geography_context
  financial_context
  care_responsibilities[]
  identity_transitions[]
  horizons[]
  uncertainties[]
```

```text
Season
  metadata
  title
  effective_interval
  status: draft | calibration | active | transitioning | complete | abandoned
  rationale
  triggering_context[]
  portfolio_items[]:
    direction_id
    role: primary | foundation | maintenance | exploration | dormant
    allocation_band: minimal | low | moderate | high | dominant
    minimum_viable_commitment?
    sacrifice_limit?
    success_signals[]
    review_date?
  constraints[]
  protected_experiences[]
  known_tradeoffs[]
  transition_notes?
```

Rules:

- at most two `primary` directions by default; override requires explicit explanation;
- foundation directions can constrain primaries;
- dormant means intentionally not optimized, not failed;
- portfolio allocation is categorical by default, not a hidden percentage sum;
- a season revision creates a new version or transition event, never history rewrite.

## A.3 Situation and context snapshot

```text
ContextSnapshot
  id
  as_of
  built_at
  location_context?
  calendar_window[]
  health_state:
    sleep_summary?
    readiness_features?
    symptoms_or_constraints[]
    freshness
  active_season_version_id
  active_commitments[]
  current_intents[]
  unresolved_decisions[]
  planned_training?
  social_or_relationship_commitments[]
  travel_state?
  weather_context?
  recent_intervention_burden
  data_quality[]
  missing_material_context[]
  source_fact_ids[]
  builder_version
```

A `ContextSnapshot` is immutable and reproducible. It is not the current-state table itself. Recommendations reference the exact snapshot used.

## A.4 Capture and observations

```text
Capture
  metadata
  captured_at
  original_payload:
    kind: text | audio | image_ref | file_ref | structured_quick_action
    content_or_object_ref
    content_hash
  initial_context:
    device_id
    timezone
    broad_location?
    invoking_surface
  interpretation_status
  interpretation_versions[]
```

```text
Observation
  metadata
  subject_id
  observation_type
  value: TypedValue
  unit?
  occurred_interval
  observed_at
  source_record_id
  quality
  epistemic_state
  corrections[]
```

Interpretation can suggest observations and entity links. User acceptance is recorded separately when material.

## A.5 Direction, commitment, project, and action

```text
Direction
  metadata
  title
  description
  serves_charter_elements[]
  horizon
  desired_change
  constraints[]
  status
```

```text
Commitment
  metadata
  statement
  parties[]
  effective_interval
  importance
  reversibility
  externality
  renegotiation_terms?
  fulfillment_state
  linked_direction_ids[]
```

```text
Action
  metadata
  action_type
  description
  status: proposed | prepared | scheduled | started | completed | skipped |
          cancelled | failed | superseded
  planned_interval?
  actual_interval?
  linked_decision_id?
  linked_intent_id?
  external_system_ref?
  completion_evidence[]
  effort_estimate?
  outcome_ids[]
```

A project is a coordinated collection of actions with a completion condition. A direction can persist without completion.

## A.6 Decision contract

```text
Decision
  metadata
  question
  status: candidate | active | deferred | chosen | enacted | closed | superseded
  detected_at
  decision_window
  stakes: low | medium | high | critical
  importance_dimensions[]
  reversibility: reversible | costly_to_reverse | irreversible | unknown
  externality: private | affects_known_people | public_or_contractual
  urgency
  current_context_snapshot_id
  charter_and_season_refs[]
  option_ids[]
  recommendation_id?
  missing_information[]
  decision_owner: user | delegated_within_scope
  follow_up_plan?
```

```text
DecisionOption
  metadata
  decision_id
  label
  description
  prerequisites[]
  consequences[]:
    outcome_type
    direction: beneficial | harmful | mixed | neutral
    magnitude_band
    time_horizon
    probability_or_uncertainty?
    evidence_refs[]
    assumptions[]
  opportunity_costs[]
  value_alignment[]
  constraint_violations[]
  reversibility
```

```text
Recommendation
  metadata
  decision_id?
  intervention_opportunity_id?
  recommended_option_or_action
  rationale_short
  rationale_structured[]
  counterarguments[]
  material_uncertainties[]
  what_would_change_this[]
  evidence_pack_id
  confidence_band
  generation_method: deterministic | hybrid | model
  policy_result_id
```

```text
Choice
  metadata
  decision_id
  selected_option_id?
  adapted_action?
  chosen_at
  rationale_optional
  confidence_optional
  source: explicit_user | standing_authority | imported_external
  supersedes_choice_id?
```

## A.7 Consequence contract

```text
ConsequenceCandidate
  id
  source_action_or_option
  affected_state_or_landmark
  causal_path[]
  direction
  expected_magnitude_band
  uncertainty_band
  earliest_effect
  latest_relevant_effect?
  accumulation_model: none | count | dose | debt | threshold | custom
  decay_model?
  assumptions[]
  personal_evidence_refs[]
  population_evidence_refs[]
  rule_or_model_version
```

The engine may emit no candidate. It must never translate an association into a causal path without marking the epistemic gap.

## A.8 Intent and intervention contracts

```text
Intent
  metadata
  statement
  serves_direction_ids[]
  desired_behavior_or_state
  opportunity_definition:
    predicates[]
    ideal_context[]
    disqualifiers[]
  temporal_policy:
    earliest
    deadline?
    recurrence?
    cooldown?
    expiry
  importance
  default_intervention_options[]
  fallback_behavior
  authority_level
  status
```

```text
InterventionOpportunity
  metadata
  intent_id
  context_snapshot_id
  detected_at
  valid_interval
  trigger_sources[]
  opportunity_confidence
  expected_benefit
  expected_interruption_cost
  urgency
  candidate_interventions[]
  prior_burden
  policy_status: pending | suppress | ambient | visible | expired
  policy_reasons[]
```

```text
Intervention
  metadata
  opportunity_id
  kind: in_app | widget | watch | local_notification | remote_notification |
        live_activity | alarm | digest
  content_template_version
  rendered_content
  scheduled_at?
  delivered_at?
  expiry
  redaction_level
  action_buttons[]
  delivery_receipt?
  interaction?
  outcome_refs[]
```

## A.9 Person and relationship contracts

```text
Person
  metadata
  display_name
  contact_external_refs[]
  user_authored_notes?
  privacy_scope
```

```text
RelationshipAssertion
  metadata
  person_id
  relationship_kind
  significance_band?
  context_label?
  valid_interval
  user_authored: boolean
  epistemic_state
  boundaries[]
  do_not_infer_fields[]
```

```text
MeaningfulContact
  metadata
  person_ids[]
  occurred_interval
  medium?
  meaningfulness: user_stated | inferred_candidate | accepted
  shared_experience_id?
  notes?
```

No schema field should be named `relationship_score`, `value`, `rank`, or `ROI`.

## A.10 Evidence contracts

```text
EvidenceSource
  metadata
  title
  authors[]
  publication
  publication_date
  source_type: systematic_review | meta_analysis | randomized_trial |
               observational | guideline | expert_consensus | mechanism |
               qualitative | official_documentation | personal_experiment |
               personal_observation | other
  identifiers: DOI/PMID/URL/etc
  version_or_retraction_state
  acquisition_and_license
  content_hash?
```

```text
EvidenceClaim
  metadata
  source_id
  claim_text_normalized
  exact_support_span_refs[]
  population
  exposure_or_intervention
  comparator?
  outcomes[]
  effect_estimates[]
  limitations[]
  domain_tags[]
  appraisal_id
```

```text
ClaimAppraisal
  metadata
  claim_id
  study_design_quality
  risk_of_bias
  inconsistency
  indirectness
  imprecision
  publication_bias_or_reporting_concern
  applicability_to_user
  overall_confidence
  appraised_by
  review_due_at?
```

```text
EvidencePack
  id
  question
  personal_facts[]
  scientific_claims[]
  contradictory_claims[]
  exclusions[]
  retrieval_query_and_version
  assembled_at
  freshness
```

## A.11 Hypothesis and experiment contracts

```text
Hypothesis
  metadata
  statement
  domain
  proposed_causal_direction?
  supporting_observations[]
  counterevidence[]
  plausible_confounders[]
  prior_plausibility
  status: exploratory | review | experiment_eligible | rejected |
          supported | inconclusive | superseded
```

```text
PersonalExperiment
  metadata
  title
  preregistration
  eligibility_criteria
  intervention_conditions[]
  assignment_method
  unit_of_randomization
  washout_or_carryover_policy?
  primary_outcome
  secondary_outcomes[]
  measurement_plan
  sample_or_cycle_target
  analysis_plan
  multiple_testing_policy
  stop_rules[]
  adverse_event_policy
  start/end
  status
  result_id?
```

```text
ExperimentResult
  metadata
  experiment_id
  adherence
  missingness
  effect_estimate
  interval_or_uncertainty
  sensitivity_analyses[]
  protocol_deviations[]
  interpretation
  replication_state
  decision_implications[]
```

## A.12 Archive contracts

```text
Episode
  metadata
  title_candidate
  temporal_interval
  place_ids[]
  person_ids[]
  member_event_ids[]
  media_refs[]
  source_linked_summary?
  significance_assertions[]
  status: candidate | accepted | edited | rejected
```

```text
ChapterVersion
  metadata
  chapter_id
  title
  temporal_interval
  episode_ids[]
  themes[]
  narrative
  source_annotations[]
  alternative_interpretations[]
  accepted_at?
```

Narrative fields cannot contain unsupported quotes. Every factual sentence should be linkable to member records.

## A.13 Trust, permissions, and authority

```text
StandingAuthorization
  metadata
  capability
  action_class
  resource_scope
  max_frequency_or_amount?
  valid_interval
  authority_level
  required_conditions[]
  prohibited_conditions[]
  revocation_state
  last_reviewed_at
```

```text
PolicyDecision
  id
  requested_action
  context_snapshot_id
  authority_required
  authorization_refs[]
  risk_factors[]
  decision: allow | require_confirmation | deny | defer
  explanation
  policy_version
```

## A.14 Product and model operation

```text
ModelRun
  metadata
  capability
  capability_version
  provider
  model_snapshot
  prompt_hash
  output_schema_version
  retrieval_pack_id?
  tool_call_ids[]
  input_data_classes[]
  route_policy
  started_at/completed_at
  usage_and_cost
  output_ref
  validation_result
  fallback_chain[]
  user_feedback_refs[]
```

```text
ProductChangeProposal
  metadata
  observed_pattern
  supporting_product_event_query
  sample_summary
  counterexamples[]
  alternative_explanations[]
  proposed_change
  affected_invariants[]
  expected_benefit
  possible_harms[]
  experiment_plan
  rollback
  status
```

---

# Appendix B. API and event contracts

## B.1 Error envelope

```json
{
  "error": {
    "code": "SYNC_CONFLICT_REQUIRES_REVIEW",
    "message": "Two season revisions changed overlapping fields.",
    "retryable": false,
    "correlation_id": "019...",
    "details": {
      "conflict_id": "019..."
    }
  }
}
```

Never expose provider stack traces or personal payloads in API errors.

## B.2 Sync push

```http
POST /v1/sync/push
Authorization: Bearer ...
Idempotency-Key: <batch-id>
```

```json
{
  "device_id": "019...",
  "client_schema_version": 12,
  "base_cursor": "c_10532",
  "operations": [
    {
      "operation_id": "019...",
      "device_sequence": 884,
      "entity_type": "meal_entry",
      "entity_id": "019...",
      "mutation_type": "create",
      "base_revision": null,
      "payload": {},
      "created_at": "2026-08-15T18:10:00Z"
    }
  ]
}
```

Response:

```json
{
  "accepted": [
    {
      "operation_id": "019...",
      "canonical_revision": 1,
      "server_change_id": 10533
    }
  ],
  "rejected": [],
  "conflicts": [],
  "next_cursor": "c_10533",
  "server_time": "2026-08-15T18:10:02Z",
  "minimum_client_schema_version": 10
}
```

## B.3 Sync pull

```http
GET /v1/sync/changes?cursor=c_10533&limit=500
```

Response contains ordered canonical changes, tombstones, and the next cursor. Changes include origin operation/device so the client can acknowledge its own writes without duplicating UI events.

## B.4 Context request

```http
POST /v1/context/assemble
```

```json
{
  "as_of": "2026-08-15T21:45:00+01:00",
  "horizon": "P3D",
  "purpose": "sleep_consequence",
  "requested_domains": ["sleep", "training", "calendar", "season"],
  "client_known_freshness": {}
}
```

Response is a `ContextSnapshot` plus missing/denied/stale data declarations.

## B.5 Decision preparation

```http
POST /v1/decisions/prepare
```

```json
{
  "question": "Should I complete the interval workout tomorrow morning?",
  "context_snapshot_id": "019...",
  "known_options": [],
  "desired_depth": "interactive",
  "max_latency_ms": 8000
}
```

The server may return:

- a complete structured decision;
- deterministic context only with `recommendation_status=insufficient_evidence`;
- an information request when material;
- an asynchronous workflow handle only for explicitly deep research.

## B.6 Intervention evaluation

```http
POST /v1/intents/opportunities/evaluate
```

```json
{
  "opportunity_id": "019...",
  "delivery_capabilities": {
    "local_notification": true,
    "live_activity": false,
    "watch_reachable": true
  },
  "client_state": {
    "foreground": false,
    "focus_redaction": "private",
    "recently_handled": false
  }
}
```

Response:

```json
{
  "policy": "ambient",
  "reason_codes": ["BENEFIT_POSITIVE", "INTERRUPTION_COST_TOO_HIGH"],
  "surface": "widget_snapshot",
  "expires_at": "2026-08-15T22:30:00+01:00",
  "policy_version": "intent-policy-1.4"
}
```

## B.7 Feedback/correction

```http
POST /v1/recommendations/{id}/feedback
```

```json
{
  "feedback_type": "wrong_context",
  "correction": {
    "assertion_id": "019...",
    "replacement": "Tomorrow's workout was cancelled"
  },
  "apply_scope": "this_event_only"
}
```

Correction handling must report the durable records changed and whether future recommendations are affected.

## B.8 Evidence query

```http
POST /v1/evidence/query
```

```json
{
  "question": "How does late caffeine affect sleep?",
  "population_context": {"adult": true},
  "personal_context_scope": "approved_sleep_and_caffeine",
  "source_policy": {
    "minimum_quality": "moderate",
    "include_emerging": true,
    "require_counterevidence": true
  }
}
```

Response separates scientific claims, personal observations, personal experiments, applicability, and uncertainties.

## B.9 Export

```http
POST /v1/exports
```

```json
{
  "scope": "all_odyssey_owned_data",
  "formats": ["jsonl", "csv", "markdown"],
  "include_raw_sources": true,
  "include_model_traces": false,
  "encryption": {
    "mode": "owner_passphrase"
  }
}
```

Export is asynchronous, resumable, owner-authenticated, and produces a signed manifest.

## B.10 Domain events

Every event uses:

```text
DomainEvent
  event_id
  event_type
  event_schema_version
  aggregate_type
  aggregate_id
  occurred_at
  recorded_at
  actor
  correlation_id
  causation_id?
  payload
  provenance
```

Initial event registry includes:

- `capture.recorded.v1`
- `observation.normalized.v1`
- `assertion.created.v1`
- `assertion.superseded.v1`
- `charter.revised.v1`
- `season.activated.v1`
- `season.transitioned.v1`
- `decision.detected.v1`
- `decision.recommendation_prepared.v1`
- `decision.choice_recorded.v1`
- `action.status_changed.v1`
- `outcome.observed.v1`
- `intent.opportunity_detected.v1`
- `intervention.suppressed.v1`
- `intervention.delivered.v1`
- `intervention.responded.v1`
- `evidence.claim_appraised.v1`
- `hypothesis.proposed.v1`
- `experiment.assignment_created.v1`
- `learning.accepted.v1`
- `episode.proposed.v1`
- `chapter.accepted.v1`
- `permission.revoked.v1`
- `product_change.proposed.v1`

Event schemas are immutable after release. Add versions; do not change meaning in place.

---

# Appendix C. Reference policy algorithms

The pseudocode describes invariants, not a required programming language.

## C.1 Silence gate

```text
function decideIntervention(opportunity, context, history, policy):
    if opportunity.isExpired(context.now):
        return SUPPRESS("EXPIRED")

    if context.globalProactivePause:
        return SUPPRESS("GLOBAL_PAUSE")

    if opportunity.intent.status != ACTIVE:
        return SUPPRESS("INTENT_INACTIVE")

    if context.hasMaterialStateChangeSince(opportunity.snapshot):
        opportunity = recomputeOrSuppress(opportunity, context)

    if any(opportunity.disqualifiersSatisfied(context)):
        return SUPPRESS("DISQUALIFIER")

    if opportunity.confidence < policy.minimumContextConfidence:
        return AMBIENT_OR_SUPPRESS("LOW_CONTEXT_CONFIDENCE")

    if history.sameAdviceRecentlyHandled(opportunity.semanticKey):
        return SUPPRESS("ALREADY_HANDLED")

    if history.sameAdviceRecentlyDismissed(opportunity.semanticKey):
        return SUPPRESS("RECENT_DISMISSAL")

    benefit = estimateExpectedBenefit(opportunity, context)
    burden = estimateInterruptionCost(opportunity, context, history)
    urgency = estimateUrgency(opportunity)

    if benefit <= 0:
        return SUPPRESS("NO_POSITIVE_EXPECTED_VALUE")

    if policy.visibleBudgetExhausted(context.localDay) and not urgency.high:
        return AMBIENT("BUDGET_EXHAUSTED")

    if context.isSensitiveOrSocialMoment and not urgency.critical:
        return AMBIENT_OR_DEFER("PROTECT_PRESENCE")

    if benefit - burden < policy.visibleThreshold:
        return AMBIENT("INTERRUPTION_NOT_JUSTIFIED")

    channel = chooseLeastIntrusiveEffectiveChannel(opportunity, context)
    return DELIVER(channel, explanation=topReasons(2))
```

The estimator may be learned later, but hard suppressions and authority rules remain deterministic.

## C.2 Consequence propagation

```text
function deriveConsequences(candidateAction, context, graph, models):
    frontier = directEffects(candidateAction, context)
    results = []

    while frontier not empty and withinDepthAndTimeLimits():
        effect = frontier.pop()

        if effect.pathContainsCycleWithoutAccumulationModel():
            continue

        evidence = resolveEvidence(effect.relation, context.userScope)
        uncertainty = combineUncertainty(
            relationUncertainty=effect.relation.uncertainty,
            inputQuality=context.quality(effect.inputs),
            applicability=evidence.applicability,
            modelCalibration=models.calibration(effect.type)
        )

        if uncertainty.tooHigh and effect.isNotMaterial:
            continue

        results.append(effect.with(evidence, uncertainty))

        for dependency in graph.outgoing(effect.affectedState):
            if dependency.allowedForConsequenceReasoning:
                frontier.push(propagate(effect, dependency))

    return collapseCorrelatedPathsAndRankBy(
        magnitude,
        probability,
        time,
        charterRelevance,
        reversibility,
        uncertainty
    )
```

The engine must cap path depth, prevent double-counting, and preserve the causal/associational status of every edge.

## C.3 Recommendation-strength cap

```text
function maximumRecommendationStrength(evidence, personalData, stakes):
    population = evidence.populationConfidence
    applicability = evidence.applicability
    personal = personalData.causalEvidenceLevel
    freshness = min(evidence.freshness, personalData.freshness)

    strength = lookup(population, applicability, personal, freshness)

    if stakes.high and strength < MODERATE:
        return "present_options_or_seek_information"

    if evidence.hasMaterialConflict:
        strength = downgrade(strength)

    if personalData.isObservationalOnly:
        prohibitPhrase("works for you")

    return strength
```

## C.4 Standing authority

```text
function authorize(action, context, authorizations):
    required = authorityLevel(
        reversibility=action.reversibility,
        externality=action.externality,
        sensitivity=action.sensitivity,
        financialOrContractualCost=action.cost,
        confidence=context.recommendationConfidence
    )

    matching = authorizations.filter(
        active and
        capabilityMatches(action) and
        resourceScopeContains(action.resource) and
        conditionsSatisfied(context) and
        not prohibitedConditionsSatisfied(context)
    )

    if required >= EXPLICIT_COMMIT:
        return REQUIRE_CONFIRMATION

    if no matching authorization:
        return required == INFORM ? ALLOW : REQUIRE_CONFIRMATION

    if action.exceeds(matching.maxFrequencyOrAmount):
        return REQUIRE_CONFIRMATION

    return ALLOW_WITH_AUDIT
```

## C.5 Day-alignment indicator, if experiment enabled

```text
function dayAlignment(day, activeSeason, observations):
    applicableCommitments = commitmentsExpectedOn(day, activeSeason)
    legitimateExceptions = detectExceptions(day)
    dataQuality = assessCoverage(observations)

    dimensions = {
        integrity: alignmentWithChosenCommitments(...),
        foundations: minimumViableFoundationSupport(...),
        primaryDirection: sufficientProgressNotMaximumOutput(...),
        relationshipsAndExperience: protectedMeaningfulLife(...),
        recoveryOrAdaptation: wiseResponseToConstraints(...)
    }

    for each dimension:
        contribution = cappedDiminishingContribution(dimension)
        contribution = adjustForContext(contribution, legitimateExceptions)

    if dataQuality insufficient:
        return qualitativeExplanationWithoutScore

    return {
        band: classify(dimensions),
        dimensions,
        explanation,
        uncertainty,
        noComparisonToOtherDaysUnlessComparable
    }
```

A score cannot be computed merely from completed actions. The feature is removable without affecting canonical history.

## C.6 Personal pattern promotion

```text
function assessPattern(candidate):
    if candidate.sampleSize < domain.minimumExploratoryN:
        return "insufficient_data"

    if candidate.wasDiscoveredAmongManyTests:
        applyMultiplicityPenalty()

    checkMissingnessMechanism()
    checkTemporalOrder()
    identifyConfounders()
    runRobustnessAndLeaveOneOut()
    compareAcrossSeasonsAndContexts()

    if effectUnstable or dataQualityLow:
        return "do_not_surface"

    if plausibleAssociationOnly:
        return "surface_as_observational_hypothesis"

    if safeRepeatableAndDecisionRelevant:
        return "propose_preregistered_experiment"
```

## C.7 Re-entry after absence

```text
function buildReentry(lastSeen, now):
    changes = materialChangesSince(lastSeen)
    expireStaleOpportunities()
    unresolved = rankUnresolvedByCurrentRelevance(changes)

    return ReentrySurface(
        summary = atMostThreeMaterialChanges(changes),
        oneQuestion = highestValueClarification(unresolved),
        options = ["continue", "revise season", "stay quiet"],
        suppressBacklog = true,
        noAbsencePenalty = true
    )
```

---
# Appendix D. Research and official-source register

**Research cutoff:** 15 August 2026. Rapidly changing platform and model sources must be rechecked immediately before implementation. The register supports the bracketed references in the specification; it does not imply that every design judgment is empirically proven.

## D.1 Wellbeing, motivation, relationships, and behavior

### [R01] Self-Determination Theory foundation

Ryan, R. M., & Deci, E. L. (2000). “Self-Determination Theory and the Facilitation of Intrinsic Motivation, Social Development, and Well-Being,” *American Psychologist*, 55(1), 68–78; and Deci, E. L., & Ryan, R. M. (2000). “The ‘What’ and ‘Why’ of Goal Pursuits,” *Psychological Inquiry*, 11(4), 227–268. [DOI](https://doi.org/10.1207/S15327965PLI1104_01)

Use: autonomy, competence, relatedness; autonomy-supportive interaction. Treat as a broad theoretical program, not a complete definition of flourishing.

### [R02] Interpersonal need support meta-analysis

Slemp, G. R., Field, J. G., Ryan, R. M., Forner, V. W., Van den Broeck, A., & Lewis, K. J. (2024). “Interpersonal Supports for Basic Psychological Needs and Their Relations With Motivation, Well-Being, and Performance: A Meta-Analysis,” *Journal of Personality and Social Psychology*. [DOI](https://doi.org/10.1037/pspi0000459)

Use: 4,561 effect sizes, 881 independent samples, N=443,556; supports the design emphasis on autonomy-, competence-, and relatedness-supportive behavior. Associations and meta-analytic heterogeneity do not establish that every product intervention will improve outcomes.

### [R03] Eudaimonic wellbeing

Ryff, C. D. (1989). “Happiness Is Everything, or Is It? Explorations on the Meaning of Psychological Well-Being,” *Journal of Personality and Social Psychology*, 57(6), 1069–1081. [DOI](https://doi.org/10.1037/0022-3514.57.6.1069)

Use: positive relations, autonomy, environmental mastery, purpose, growth, and self-acceptance as plural lenses rather than a score template.

### [R04] Social relationships and mortality

Holt-Lunstad, J., Smith, T. B., & Layton, J. B. (2010). “Social Relationships and Mortality Risk: A Meta-analytic Review,” *PLOS Medicine*, 7(7), e1000316. [DOI](https://doi.org/10.1371/journal.pmed.1000316)

Use: supports treating relationships as foundational. Do not translate population association into a prescriptive contact frequency.

### [R05] Implementation intentions

Gollwitzer, P. M., & Sheeran, P. (2006). “Implementation Intentions and Goal Achievement: A Meta-analysis of Effects and Processes,” *Advances in Experimental Social Psychology*, 38, 69–119. [Author PDF](https://www.socmot.uni-konstanz.de/sites/default/files/06_Gollwitzer_Sheeran_Implementation_Intentions_And_Goal.pdf)

Use: context-linked intention design. The reported aggregate effect does not mean every if-then plan is appropriate or durable.

### [R06] Habit formation variability

Lally, P., van Jaarsveld, C. H. M., Potts, H. W. W., & Wardle, J. (2010). “How Are Habits Formed: Modelling Habit Formation in the Real World,” *European Journal of Social Psychology*, 40(6), 998–1009. [DOI](https://doi.org/10.1002/ejsp.674)

Use: habits develop over variable time frames; reject fixed-day myths and universal streak mechanics.

### [R07] JITAI framework

Nahum-Shani, I., Smith, S. N., Spring, B. J., et al. (2018). “Just-in-Time Adaptive Interventions (JITAIs) in Mobile Health: Key Components and Design Principles for Ongoing Health Behavior Support,” *Annals of Behavioral Medicine*, 52(6), 446–462. [DOI](https://doi.org/10.1007/s12160-016-9830-8)

Use: distal/proximal outcomes, tailoring variables, decision points, intervention options, and decision rules.

### [R08] Micro-randomized trials

Klasnja, P., Hekler, E. B., Shiffman, S., et al. (2015). “Microrandomized Trials: An Experimental Design for Developing Just-in-Time Adaptive Interventions,” *Health Psychology*, 34S, 1220–1228. [DOI](https://doi.org/10.1037/hea0000305)

Use: repeated low-risk intervention experiments and proximal effects. Not a license to randomize consequential or unsafe advice.

### [R09] Stage-based personal informatics

Li, I., Dey, A., & Forlizzi, J. (2010). “A Stage-Based Model of Personal Informatics Systems,” *CHI 2010*. [DOI](https://doi.org/10.1145/1753326.1753409) · [Author PDF](https://personalinformatics.ianli.com/docs/lab/2010-chi-ianli-stage-based-model.pdf)

Use: preparation, collection, integration, reflection, and action as a complete product loop.

### [R10] Lived informatics

Epstein, D. A., Ping, A., Fogarty, J., & Munson, S. A. (2015). “A Lived Informatics Model of Personal Informatics,” *UbiComp 2015*. [DOI](https://doi.org/10.1145/2750858.2804250)

Use: real-world tracking lapses, resumption, and changing motivations; supports guilt-free re-entry.

### [R11] N-of-1 reporting and design discipline

Vohra, S., Shamseer, L., Sampson, M., et al. (2015). “CONSORT Extension for Reporting N-of-1 Trials (CENT) 2015 Statement,” *BMJ*, 350, h1738. [DOI](https://doi.org/10.1136/bmj.h1738)

Use: experiment reporting, protocol clarity, and limits of N-of-1 inference.

### [R12] Unintended consequences of personal informatics

Luo, Y., et al. (2025). “Reflecting Upon the Unintended Consequences of Personal Informatics Systems: A Systematic Review of Empirical Studies,” *ACM Designing Interactive Systems*. [Author PDF](https://yuhanlolo.github.io/me/papers/dis25-reflectingPI-luo.pdf)

Use: cognitive, emotional, behavioral, and social harms as first-class guardrails. Findings are heterogeneous and should inform risk design rather than imply tracking is inherently harmful.

### [R13] Metrics and goal failure

Ordóñez, L. D., Schweitzer, M. E., Galinsky, A. D., & Bazerman, M. H. (2009). “Goals Gone Wild: The Systematic Side Effects of Over-Prescribing Goal Setting,” *Academy of Management Perspectives*, 23(1), 6–16. [DOI](https://doi.org/10.5465/amp.2009.37007999). See also Manheim, D., & Garrabrant, S. (2019), “Categorizing Variants of Goodhart’s Law.” [arXiv](https://arxiv.org/abs/1803.04585)

Use: score/target anti-gaming design. Goodhart’s law is a family of failure modes, not a quantitative formula for score weights.

### [R14] Human-AI interaction guidelines

Amershi, S., Weld, D., Vorvoreanu, M., et al. (2019). “Guidelines for Human-AI Interaction,” *CHI 2019*. [DOI](https://doi.org/10.1145/3290605.3300233) · [Microsoft Research PDF](https://www.microsoft.com/en-us/research/wp-content/uploads/2019/01/Guidelines-for-Human-AI-Interaction-camera-ready.pdf)

Use: capability expectation, context-sensitive timing, correction, graceful failure, learning controls, and global controls.

### [R15] Appropriate reliance

Schemmer, M., Kühl, N., Benz, C., Bartos, A., & Satzger, G. (2023). “Appropriate Reliance on AI Advice: Conceptualization and the Effect of Explanations.” [arXiv](https://arxiv.org/abs/2302.02187)

Use: trust should be calibrated to advice quality; explanations alone do not guarantee appropriate reliance.

### [R16] Evidence confidence

GRADE Working Group. “Grading quality of evidence and strength of recommendations.” [Official site](https://www.gradeworkinggroup.org/). Foundational series: Guyatt, G. H., et al. (2008 onward), *BMJ*.

Use: risk of bias, inconsistency, indirectness, imprecision, and publication bias as inspiration for transparent appraisal. Odyssey is not a clinical guideline body and must not present its adapted bands as official GRADE ratings.

### [R17] Adult sleep duration

Watson, N. F., Badr, M. S., Belenky, G., et al. (2015). “Recommended Amount of Sleep for a Healthy Adult: A Joint Consensus Recommendation of the American Academy of Sleep Medicine and Sleep Research Society,” *Journal of Clinical Sleep Medicine*, 11(6), 591–592. [DOI](https://doi.org/10.5664/jcsm.4758)

Use: broad sleep-foundation guidance. Individual need, disorders, and performance implications require context.

### [R18] Physical activity guidance

World Health Organization (2020). *WHO Guidelines on Physical Activity and Sedentary Behaviour*. [Official publication](https://www.who.int/publications/i/item/9789240015128)

Use: broad activity foundation and public-health context; not a personalized training plan.

### [R19] Protein and resistance training

Morton, R. W., Murphy, K. T., McKellar, S. R., et al. (2018). “A Systematic Review, Meta-analysis and Meta-regression of the Effect of Protein Supplementation on Resistance Training-Induced Gains,” *British Journal of Sports Medicine*, 52, 376–384. [DOI](https://doi.org/10.1136/bjsports-2017-097608)

Use: example of domain-specific meta-analytic evidence and diminishing/conditional effects; not a universal individual prescription.

### [R20] Caffeine and sleep

Gardiner, C., Weakley, J., Burke, L. M., et al. (2023). “The Effect of Caffeine on Subsequent Sleep: A Systematic Review and Meta-analysis,” *Sleep Medicine Reviews*, 69, 101764. [DOI](https://doi.org/10.1016/j.smrv.2023.101764)

Use: supports a cautious caffeine/sleep intent and candidate personal experiment; applicability depends on dose, timing, habitual use, and individual variation.

### [R21] Intertemporal choice

Frederick, S., Loewenstein, G., & O’Donoghue, T. (2002). “Time Discounting and Time Preference: A Critical Review,” *Journal of Economic Literature*, 40(2), 351–401. [DOI](https://doi.org/10.1257/002205102320161311)

Use: theoretical background for connecting current choice to delayed consequence. Models of discounting are descriptive simplifications, not a complete model of values.

### [R22] Trust in automation

Lee, J. D., & See, K. A. (2004). “Trust in Automation: Designing for Appropriate Reliance,” *Human Factors*, 46(1), 50–80. [DOI](https://doi.org/10.1518/hfes.46.1.50_30392)

Use: trust calibration and representation of system capability/limits.

## D.2 Apple platform documentation

All Apple sources are official and were checked against public documentation available on 15 August 2026.

### [A01] HealthKit

Apple Developer Documentation, “About the HealthKit framework” and HealthKit API reference. [Official documentation](https://developer.apple.com/documentation/healthkit/about-the-healthkit-framework)

Use: Apple Health as canonical store for supported health sample types; authorization and source-aware integration.

### [A02] WorkoutKit

Apple Developer Documentation, WorkoutKit and `WorkoutScheduler`. [Official documentation](https://developer.apple.com/documentation/workoutkit/workoutscheduler)

Use: scheduled workout representation and Apple Watch synchronization where supported.

### [A03] WidgetKit refresh behavior

Apple Developer Documentation, “Keeping a widget up to date.” [Official documentation](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)

Use: widget extensions are not continuously active; dynamic budgets, typical 40–70 refreshes for frequently viewed widgets, and approximately five-minute minimum timeline spacing. These are platform guidance, not delivery guarantees.

### [A04] EventKit authorization

Apple Developer Documentation, “Accessing the event store.” [Official documentation](https://developer.apple.com/documentation/eventkit/accessing-the-event-store)

Use: write-only versus full access; reading requires full access; EventKitUI as a lower-permission alternative for editing.

### [A05] App Intents

Apple Developer Documentation, App Intents framework. [Official documentation](https://developer.apple.com/documentation/appintents)

Use: Shortcuts, Siri/system discovery, Spotlight, widgets, controls, and narrow action surfaces.

### [A06] Background location

Apple Developer Documentation, “Handling location updates in the background.” [Official documentation](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background)

Use: background location must map to a legitimate feature and supported delivery mode; not a general always-running context engine.

### [A07] BackgroundTasks

Apple Developer Documentation, `BGProcessingTask` and Background Tasks framework. [Official documentation](https://developer.apple.com/documentation/backgroundtasks/bgprocessingtask)

Use: processing tasks are system-scheduled, idle-time, interruptible work; not precise alarms.

### [A08] AlarmKit

Apple Developer Documentation, AlarmKit. [Official documentation](https://developer.apple.com/documentation/alarmkit)

Use: explicit user-authorized alarm/countdown experiences. It is not a generic notification bypass.

### [A09] Foundation Models

Apple Developer Documentation, “Generating content and performing tasks with Foundation Models.” [Official documentation](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)

Use: on-device generation, guided structured output, and tools on supported Apple Intelligence devices; availability must be checked and fallback supplied.

### [A10] ActivityKit / Live Activities

Apple Developer Documentation, “Displaying live data with Live Activities.” [Official documentation](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)

Use: bounded live processes, not a permanent life dashboard.

### [A11] CKSyncEngine alternative

Apple Developer Documentation, `CKSyncEngine`. [Official documentation](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5)

Use: considered as an Apple-native sync alternative. Not selected as the primary architecture because Odyssey requires portable backend jobs, integrations, AI, and relational temporal queries; the decision should be revisited if scope becomes device-only.

### [A12] Current beta boundary

Apple Developer Documentation, “iOS & iPadOS 27 Beta 5 Release Notes,” and Apple Developer release dated 10 August 2026. [Official release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)

Use: confirms iOS 27 was beta at the research cutoff. Beta-only APIs must remain isolated and unavailable in production until public release and revalidation.

### [A13] User notifications

Apple Developer Documentation, UserNotifications framework. [Official documentation](https://developer.apple.com/documentation/usernotifications)

Use: local/remote notification request and action surfaces; delivery must still be treated according to system policy.

### [A14] WeatherKit

Apple Developer, WeatherKit. [Official documentation](https://developer.apple.com/weatherkit/)

Use: supported weather context for training, travel, and planning, subject to entitlement, attribution, and service terms.

## D.3 Data, synchronization, cloud, and observability

### [D01] Local-first architecture

Kleppmann, M., Wiggins, A., van Hardenberg, P., & McGranaghan, M. (2019). “Local-First Software: You Own Your Data, in spite of the Cloud.” [Ink & Switch paper](https://www.inkandswitch.com/local-first/)

Use: local responsiveness/offline ownership principles. Odyssey still uses a conventional cloud authority for cross-device canonical revisions and jobs rather than adopting every local-first/CRDT technique.

### [D02] Event sourcing

Fowler, M. “Event Sourcing.” [Technical article](https://martinfowler.com/eaaDev/EventSourcing.html)

Use: audit/replay benefits and conceptual background. The specification intentionally chooses a selective ledger plus relational projections rather than event-sourcing every mutation.

### [D03] SQLite WAL

SQLite Documentation, “Write-Ahead Logging.” [Official documentation](https://sqlite.org/wal.html)

Use: local concurrency and durability design; implementation must still test checkpointing and backup behavior on Apple platforms.

### [D04] OpenTelemetry

OpenTelemetry Project, “What is OpenTelemetry?” and specification. [Official documentation](https://opentelemetry.io/docs/what-is-opentelemetry/)

Use: vendor-neutral trace, metric, and log instrumentation.

### [D05] PostgreSQL

PostgreSQL Global Development Group, PostgreSQL current documentation. [Official documentation](https://www.postgresql.org/docs/current/)

Use: relational/temporal ranges, transactions, full text, backup, constraints, and schema evolution. Deploy a stable supported version, not a beta feature assumed by this document.

### [D06] pgvector

pgvector project. [Official repository](https://github.com/pgvector/pgvector)

Use: embeddings colocated with relational metadata at expected single-user scale.

### [D07] Cloud Run

Google Cloud, “What is Cloud Run?” [Official documentation](https://cloud.google.com/run/docs/overview/what-is-cloud-run)

Use: managed portable-container execution for API and workers.

### [D08] Cloud SQL point-in-time recovery

Google Cloud, “Use point-in-time recovery (PITR).” [Official documentation](https://cloud.google.com/sql/docs/postgres/backup-recovery/pitr)

Use: cloud durability and disaster-recovery design. PITR does not replace logical export or restore drills.

### [D09] Cloud Tasks semantics

Google Cloud, “Understand Cloud Tasks.” [Official documentation](https://cloud.google.com/tasks/docs/dual-overview)

Use: asynchronous work, at-least-once delivery, weak timing guarantees, and idempotent handlers.

### [D10] Cloud Storage soft delete and versioning

Google Cloud Storage documentation, “Soft delete” and “Object Versioning.” [Soft delete](https://cloud.google.com/storage/docs/soft-delete) · [Versioning](https://cloud.google.com/storage/docs/object-versioning)

Use: object recovery layers. Retention and deletion behavior must be configured and tested explicitly.

### [D11] Secret Manager

Google Cloud, Secret Manager overview. [Official documentation](https://cloud.google.com/secret-manager/docs/overview)

Use: service and integration secret storage; mobile clients must not receive backend secrets.

### [D12] Temporal knowledge graphs — emerging research

Survey literature on temporal knowledge graphs, including current arXiv surveys available by the cutoff. [Example survey search](https://arxiv.org/search/?query=temporal+knowledge+graph+survey&searchtype=all)

Use: conceptual support for time-scoped edges and temporal retrieval. This is an emerging field and does not justify making a specialized graph database canonical.

### [D13] Agent/memory architecture — emerging research

Current surveys on memory mechanisms for LLM-based agents. [Example survey search](https://arxiv.org/search/?query=memory+mechanisms+LLM+agents+survey&searchtype=all)

Use: background for layered memory and retrieval. The architecture relies on conventional durable data and provenance rather than accepting an agent-memory framework as the source of truth.

## D.4 Foundation-model, tool, and agent documentation

These capabilities change quickly. Re-evaluate models, pricing, retention, API status, and SDK behavior before implementation.

### [M01] OpenAI Agents SDK

OpenAI, Agents SDK documentation. [Official documentation](https://openai.github.io/openai-agents-python/)

Use: current distinction between direct Responses API ownership of loop/tool/state and SDK-managed turns, tools, guardrails, sessions, and multi-step artifacts.

### [M02] OpenAI structured outputs and function tools

OpenAI Platform documentation, Structured Outputs / function calling. [Official documentation](https://platform.openai.com/docs/guides/structured-outputs)

Use: schema-constrained outputs. Validation, authorization, and factual verification remain application responsibilities.

### [M03] Anthropic tool use

Anthropic documentation, Tool use. [Official documentation](https://docs.anthropic.com/en/docs/agents-and-tools/tool-use/overview)

Use: provider comparison and tool schema behavior; not selected as a fixed architectural dependency.

### [M04] Google Agent Development Kit

Google, Agent Development Kit documentation. [Official documentation](https://google.github.io/adk-docs/)

Use: alternative framework evaluation and Google ecosystem integration; not a default requirement.

### [M05] Model Context Protocol

Model Context Protocol, specification dated 28 July 2026. [Official specification](https://modelcontextprotocol.io/specification/2026-07-28)

Use: potential standardized connector/tool boundary. The specification itself emphasizes consent, data control, and tool risk; MCP does not replace Odyssey’s authorization layer.

### [M06] OpenAI evaluations guidance

OpenAI Platform documentation, Evals. [Official documentation](https://platform.openai.com/docs/guides/evals)

Use: current evaluation workflow ideas. Store Odyssey’s cases, rubrics, and reports in provider-neutral repository formats rather than relying exclusively on a hosted eval product.

## D.5 Integration documentation

### [I01] Strava API

Strava Developers, API documentation including OAuth and webhooks. [Official documentation](https://developers.strava.com/docs/)

Use: supported activity integration after HealthKit/core loops; token, webhook, rate-limit, and single-user application rules must be rechecked.

### [I02] GitHub GraphQL API

GitHub Docs, GraphQL API. [Official documentation](https://docs.github.com/en/graphql)

Use: user-authorized career/coding context where it changes a decision or archive, not an engineering-output vanity score.

### [I03] LinkedIn access constraints

Microsoft Learn / LinkedIn, “Getting Access to LinkedIn APIs.” [Official documentation](https://learn.microsoft.com/en-us/linkedin/shared/authentication/getting-access)

Use: supports the conclusion that access is product/program gated; avoid scraping or assuming applicant/job automation APIs are generally available.

### [I04] TrueLayer Data API

TrueLayer Documentation, Data API overview. [Official documentation](https://docs.truelayer.com/docs/data-api-overview)

Use: example of a supported open-banking route if a concrete financial decision loop later justifies it. Regional availability, consent, regulation, and commercial terms must be checked.

### [I05] OAuth security

IETF, RFC 9700, “Best Current Practice for OAuth 2.0 Security.” [Official RFC](https://www.rfc-editor.org/rfc/rfc9700)

Use: OAuth connector security, PKCE/current best practice, redirect and token handling.

## D.6 Source-quality policy

When adding new sources:

1. prefer systematic reviews/meta-analyses for broad empirical claims;
2. prefer randomized evidence when causal intervention effects are material and feasible;
3. use high-quality observational evidence with explicit causal limits;
4. use official platform/vendor documentation for technical capability;
5. record publication and retrieval dates for fast-moving APIs;
6. seek disconfirming evidence;
7. store the exact claim-support span where licensing permits;
8. never treat a model summary as the source;
9. distinguish authoritative documentation from marketing;
10. mark preprints and emerging surveys clearly.

---

# Appendix E. Requirements traceability and final definition of done

## E.1 Commission-to-specification traceability

| Commission requirement | Primary specification location |
|---|---|
| Good-life philosophy and North Star | §§2–6 |
| Product Constitution | §3 |
| Challenge premises/contradictions | §4 |
| Current season and changing stages | §§6–7 |
| Ontology and temporal semantics | §8, Appendix A |
| Decision system | §9, Appendix A.6 |
| Temporal consequence engine | §10, Appendix C.2 |
| Context-aware intent/intervention | §11, §26, Appendix C.1 |
| Maximum memory/selective attention | §12, §22 |
| Personal learning/N-of-1 | §13, §43, Appendix A.11 |
| Scientific evidence | §14, Appendix A.10, Appendix D |
| Scores/Goodhart | §15, Appendix C.5 |
| AI philosophy and architecture | §16, §24 |
| Trust/reversibility/agency | §17, §30, Appendix C.4 |
| Experience architecture | §18 |
| Visual/stateful art | §19 |
| Apple ecosystem and constraints | §20, §26 |
| Integrations | §21 |
| Data/backend/offline/sync | §§22–25 |
| Background/notifications | §26 |
| Observability | §27 |
| Product telemetry/self-improvement | §28 |
| Evaluations | §29 |
| Security/privacy | §30 |
| Durability/migrations | §31 |
| Failure modes | §32 |
| Technology alternatives | §33 |
| Repository/testing/deployment | §§34–36 |
| Development environments | §37 |
| Roadmap/dependencies/first/deferred | §§38–41 |
| Open questions and experiments | §§42–43 |
| One-week/month evaluation | §§44–45 |
| Next iteration and agent handoff | §§46–47 |
| Stress testing | §48 |
| Detailed schemas/APIs/policies | Appendices A–C |
| Research citations | Appendix D |

## E.2 Product definition of done for the first lived edition

The first lived edition is complete only when all are true:

### Philosophy and experience

- the owner has accepted a Charter, life-stage context, and season version;
- Now can intentionally show silence;
- no universal Life Score exists;
- no feature ranks people;
- re-entry after absence is guilt-free;
- all enabled proactive copy follows the two-line concise contract.

### Durability

- capture commits locally offline;
- sync converges across at least two devices in test;
- migration fixtures pass;
- owner export is intelligible;
- cloud backup and PITR are enabled;
- clean-room restore has succeeded;
- no release step instructs wiping production data.

### Apple integration

- HealthKit and calendar permissions are incremental and revocable;
- denied permissions degrade gracefully;
- widget content is cached and freshness-aware;
- background behavior is tested on physical devices;
- no beta-only API is required for production;
- Watch interactions function offline for supported quick actions.

### Intelligence

- deterministic context exists without a model;
- every model output is versioned and structured when consequential;
- recommendations cite personal/scientific inputs;
- uncertainty and insufficiency are valid outputs;
- provider failure has a defined fallback;
- prompt-injection and sensitive-route tests pass;
- model change rollback exists.

### Intervention and authority

- notification budget and silence gate are active;
- every opportunity expires;
- delivery-time state is rechecked;
- standing permissions are visible/revocable;
- external actions cannot occur without required confirmation;
- global proactive pause works from all active devices after sync.

### Evidence and evaluation

- source and claim provenance are inspectable;
- population versus personal evidence is distinct;
- historical replay suite passes;
- severe real failures have regression cases;
- one-week protocol is runnable;
- product telemetry answers declared questions and excludes meaningless engagement events.

### Security and operations

- threat model is current;
- secrets are externalized;
- production access is least privilege;
- sensitive notifications are redacted;
- logs are payload-safe;
- incident, token-revocation, and lost-device runbooks exist;
- budget and backup alerts reach a channel outside Odyssey.

### Handoff

- a fresh machine can clone and run the credential-free stack from documentation;
- the owner handoff lists every account, entitlement, secret, and manual step;
- architecture decisions and deviations are recorded;
- known limitations and deliberate deferrals are explicit;
- repository contains no real personal data or unmanaged credentials.

## E.3 Final decision

Odyssey should be built—not as a totalizing intelligence that evaluates every hour, but as a durable navigation layer that is unusually good at a few things humans and existing apps handle poorly together:

- maintaining a truthful, changing account of what matters;
- assembling distant context at consequential moments;
- making repeated good actions cheaper;
- distinguishing evidence from confident language;
- preserving agency and meaningful exceptions;
- remembering a life without demanding that life be performed for the database.

The architecture deliberately leaves room for ambition. It can grow into a beautiful decades-long atlas, a scientifically responsible personal laboratory, and a highly capable decision-support system. Its legitimacy, however, must be earned in the opposite order from a speculative demo: **durability first, context second, restraint third, intelligence fourth, and spectacle last.**
