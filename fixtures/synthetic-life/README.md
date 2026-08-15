# Synthetic life fixtures

All repository fixtures are deterministic and contain no real personal data.
The checked-in `generated/v1` dataset spans three years and includes:

- ordinary office and home workdays;
- missing and stale observations;
- endurance and strength training;
- temporary illness constraints;
- interview decisions and preparation;
- explicit relationship commitments without ranking;
- international travel and timezone changes;
- annual season transitions;
- conflicting two-device season edits;
- auditable intervention suppression;
- source-linked archive episode candidates.

Regenerate the canonical fixture:

```bash
make fixtures
```

Generate a larger performance fixture without committing it:

```bash
cd backend
uv run python ../tools/fixtures/generate_synthetic_life.py \
  --years 10 --output /tmp/odyssey-synthetic-10y
```

`ledger.jsonl` contains versioned domain events. `source-records.jsonl` contains
the synthetic source records those events reference. `manifest.json` records
scenario counts and content hashes.

