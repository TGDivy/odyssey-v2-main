# Assumptions Log

This log records implementation assumptions that require later validation. An
assumption is not product truth and must not silently become a permanent policy.

| ID | Assumption | Validation or reversal trigger | Status |
| --- | --- | --- | --- |
| A-001 | The repository remains a single-owner private deployment initially. | Add tenant isolation before any second owner or shared account. | Active |
| A-002 | Google Cloud is the reference deployment while containers and SQL remain portable. | Record an ADR before selecting another production cloud. | Active |
| A-003 | PostgreSQL 17 and SQLite 3 are sufficient for ledger, temporal, search, and vector workloads. | Revisit only after measured query or operational limits. | Active |
| A-004 | Cloud AI is disabled by default and deterministic fakes cover credential-free development. | Enable a provider only after privacy policy and evaluation gates pass. | Active |
| A-005 | Apple signing, HealthKit/WeatherKit entitlements, and physical-device checks happen on the owner's Mac. | Deployment handoff and capability report prove configuration. | Active |
| A-006 | No real personal data enters source control, CI fixtures, or shared development environments. | Any exception requires a documented approval and sanitization policy. | Active |
