# Odyssey evaluation artifacts

This directory contains versioned, provider-neutral evaluation inputs. It must
contain synthetic or explicitly owner-approved material only. Never commit raw
owner history, provider payloads, private report output, or model credentials.

## Version 1 inventory

- `cases/scenario-stress.v1.json` encodes all twenty scenarios in Appendix 48
  using the complete §29.2 `EvalCase` shape.
- `rubrics/core.v1.json` defines eight quality and safety rubrics. Every
  dimension has explicit 0–4 anchors and fail-closed conditions.
- `golden/deterministic-policies.v1.json` replays fixed inputs through the real
  authority, day-alignment, intervention, pattern, recommendation-strength,
  and re-entry policies.
- `manifest.v1.json` seals the three corpus files with SHA-256 digests and
  expected item counts.

The JSON contracts are generated under `schemas/jsonschema/v1/`. The corpus
runner also enforces exact Appendix 48 IDs, synthetic provenance, rubric
references, non-executable scenario authority, complete adapter coverage,
golden output equality, and named safety invariants.

## Validate

From the repository root:

```bash
cd backend
uv run python ../tools/evals/run.py --check
```

The output includes corpus version, counts, and a digest derived from the
sealed files. `tools/verify.sh` runs the same command.

## Change workflow

1. Add or revise a case as a new version; do not silently change the meaning
   of a previously reported case.
2. Keep committed cases synthetic. Reconstructed or historical owner cases
   require de-identification or explicit permission and should normally live
   in a private evaluation store.
3. Make the expected invariants specific enough to detect a substantive
   failure, while allowing multiple acceptable responses.
4. Execute golden inputs against production policy functions and review the
   output. Never hand-adjust expected output to hide unexplained drift.
5. Compute SHA-256 for each sealed corpus file, update `manifest.v1.json`, and
   run the corpus check plus focused tests.
6. Regenerate public schemas with `make schemas` when a contract changes.
7. Record regressions from substantive failures as new cases with provenance.

Open-ended model outputs are scored using `docs/evaluation-protocols.md`; they
are not accepted merely because deterministic replay passes.
