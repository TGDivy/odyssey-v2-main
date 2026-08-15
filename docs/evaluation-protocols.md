# Evaluation protocols

This document operationalizes the repository-supported portion of §§29 and 48
of the master specification. It does not claim a deployed model, live shadow
traffic, owner history, Apple-device behavior, or longitudinal outcomes.

## Current evidence boundary

| Evaluation layer | Current repository evidence | Remaining proof |
| --- | --- | --- |
| Deterministic unit/property tests | Backend and portable Swift tests plus six policy golden replays | Broader property and platform integration coverage |
| Dataset component evaluation | Strict synthetic Appendix 48 corpus and anchored rubrics | Retrieval, scientific-claim, model, security, UI, and performance datasets |
| Historical replay | Contracts support reconstructed and owner-approved provenance | Private frozen snapshots with explicit owner permission |
| Adversarial/safety scenarios | All twenty Appendix 48 scenarios are versioned and manifest-sealed | Execute and grade every applicable product/model surface |
| Live shadow evaluation | Not enabled | Deployed provider, privacy review, feature flag, monitoring, and owner approval |
| Longitudinal real-use evaluation | Not started | One-week and one-month owner protocols after prerequisite product loops exist |

Passing the repository runner proves corpus integrity and deterministic policy
behavior only. It does not prove that an open-ended model response deserves a
passing rubric score.

## Corpus validation

Run from a credential-free checkout:

```bash
cd backend
uv run python ../tools/evals/run.py --check
uv run pytest tests/unit/test_evaluation_corpus.py
```

The first command validates strict Pydantic contracts, complete stress-scenario
and replay-adapter inventories, allowed rubric references, scenario authority
limits, exact golden outputs, named invariants, item counts, and SHA-256 file
digests. The second command protects the contracts and fail-closed behavior.

## Scoring an open-ended response

1. Freeze the case version, implementation version, model/provider identifier,
   prompt/tool versions, policy versions, feature flags, and scenario time.
2. Provide only `permitted_data_scope`. Record every unavailable, denied, or
   intentionally excluded source from `frozen_context_snapshot`.
3. Preserve the raw structured output, tool trace, cited source identifiers,
   latency, cost, schema failures, and fallback path in a private review store.
4. Check `expected_invariants` and `unacceptable_outputs` before subjective
   grading. Any rubric hard-fail condition fails the case regardless of mean.
5. Score each applicable rubric dimension from 0 through 4 using its explicit
   anchor. Do not invent half-points unless a later rubric version permits them.
6. Compute each rubric score as the sum of `score * weight` divided by the sum
   of weights. Compare it with `minimum_weighted_score`.
7. For consequential health, relationship, financial, contractual, or external
   action classes, perform independent evidence and authority-policy checks.
   Model grading alone cannot pass a high-stakes case.
8. Record evaluator identity/type, rationale, disagreement, hard failures, and
   a correction or regression-case link. Retain dimensions; do not collapse the
   report into a single Odyssey score.

Human review is required for nuanced tone, usefulness, privacy expectations,
and scientific applicability. A second model may triage output but is not a
source of truth.

## Model or prompt change gate

Before changing any enabled production model, provider route, system prompt,
tool contract, or policy-affecting generation configuration:

1. run repository verification and capability-specific golden cases;
2. compare candidate and incumbent on identical frozen inputs;
3. inspect every regression and hard failure, not only aggregate scores;
4. run approved private historical replays when they exist;
5. compare structured-output reliability, latency, cost, retention terms, and
   regional processing assumptions;
6. complete security and prompt-injection review for changed tool/data access;
7. shadow behind a disabled-by-default feature flag where lawful and approved;
8. document rollback criteria and retain the incumbent configuration;
9. enable narrowly, monitor corrections/schema failures, and roll back on any
   authority, privacy, durability, or unsupported-claim hard failure.

No model is currently selected or enabled merely by this corpus. Provider and
model gates remain closed until the relevant evaluation and owner deployment
steps are complete.

## Historical and regression data

- Prefer synthetic cases for source control.
- Reconstructed real cases must remove direct and indirect identifiers and
  declare reconstruction provenance.
- Exact historical snapshots require explicit owner permission, encrypted
  private storage, a defined retention period, and revocation/deletion support.
- Never place operational secrets, authentication material, message bodies, or
  unnecessary raw health/location data in a case.
- Add a versioned regression case for every substantive factual, scientific,
  privacy, authority, temporal, durability, or harmful-tone failure.
- If a corrected case changes expected behavior, retain the prior report and
  explain why a new case or corpus version supersedes it.

## Review report minimum

A review report should include corpus and case versions, implementation commit,
candidate/incumbent configuration, pass/fail by invariant, dimension scores,
hard failures, schema/fallback statistics, latency/cost, sampled traces,
regressions, reviewer notes, and an explicit promote/hold/reject decision. Keep
reports private when they include owner data; commit only de-identified summary
evidence approved for source control.

The one-week and one-month real-use protocols remain governed by §§44–45 of the
master specification. They begin only after the prerequisite owner-facing loops
are usable and safe; this repository corpus is not a substitute for living with
the product.
