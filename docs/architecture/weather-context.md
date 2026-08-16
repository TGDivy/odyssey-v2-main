# Weather context boundary

Odyssey uses weather as bounded planning context, not as a location-history
system, safety authority, or always-on background service. The implementation
is local-first and provider-neutral, with WeatherKit as the guarded Apple
adapter on supported signed targets.

## Scope

The current contract carries:

- one broad place identifier, optional owner-facing place name, and IANA time
  zone;
- current conditions;
- at most 72 ordered hourly forecasts;
- at most 14 ordered daily forecasts;
- provider request time, source observation time, and explicit expiry;
- provider name, attribution text, HTTPS legal page, and optional HTTPS light
  and dark combined-mark URLs;
- explicit fetched, unavailable, and rate-limited outcomes; and
- provider/store rejection counts suitable for integration health.

Canonical values are Celsius, metres per second, millimetres per hour,
fractions from zero through one, and integer UV index. Every finite/range,
ordering, date, freshness, URL, and text invariant is checked again when a
stored document is decoded.

Weather is context only. It must not be used as an emergency alert, medical
decision, route-safety guarantee, or exact prediction. Provider expiry is
visible and expired data is degraded rather than silently presented as fresh.

## Location privacy boundary

`WeatherQueryLocation` contains the coordinates and horizontal accuracy needed
for a provider request. It deliberately does not conform to `Codable`.
Coordinates are passed directly to the adapter and are not included in the
persisted weather document, cursor, integration-health state, logs, UI copy, or
sync outbox.

The persisted `WeatherPlaceContext` contains only a broad, application-defined
identifier, an optional broad display name, and a time zone. The coordinator
stores one mutable record named `current`; a successful query for another place
replaces that record rather than accumulating a place history. Query failures
do not persist a newly requested place.

The iOS shell exposes provider/cache health, attribution, and local revocation.
Its explicit **Refresh Broad Place and Weather** action first runs the
conservative one-shot foreground resolver and then constructs the transient
query in `ForegroundContextRefreshCoordinator`. Bootstrap and background tasks
never acquire Location or refresh Weather.

## Local mirror semantics

`WeatherMirrorCoordinator` uses `IntegrationLocalRecordStoring` with connector
`weather` and stream `forecast`:

1. load and validate the existing record and cursor;
2. obtain a transient provider result;
3. reject a returned snapshot for a different broad place;
4. reject a snapshot that is already expired or implausibly ahead of the local
   attempt clock;
5. atomically insert/update the single canonical JSON record and cursor; or
6. on unavailable/rate-limited results, update only bounded attempt diagnostics
   while preserving the previous record.

The current schema-v5 SQLite store computes and verifies the document SHA-256;
schema v4 introduced the integration-mirror tables. Weather records never
create ledger events or sync-outbox operations. Explicit **Remove Local Weather
Mirror** clears the local document and cursor; it does not modify WeatherKit,
Apple account state, source data, or location permission.

The cursor records only last attempt, last successful refresh, outcome,
rate-limit state, and rejected count. It contains no coordinates or newly
requested place. Clock rollback, malformed cursor state, an orphaned document,
multiple current records, and document/source timestamp disagreement fail
closed.

## WeatherKit adapter

`WeatherKitAdapter` is compiled only when both WeatherKit and Core Location are
available. It:

- creates an ephemeral `CLLocation` from the validated query;
- requests `Weather` and mandatory `WeatherAttribution` from
  `WeatherService`;
- uses WeatherKit metadata request/expiry timestamps and current observation
  time rather than inventing freshness;
- sorts and bounds hourly/daily forecasts before normalization;
- converts Foundation measurements to the canonical units;
- maps every currently documented `WeatherCondition` to a stable snake-case
  code and maps future unknown cases to `unknown`;
- rejects malformed current data and counts malformed forecast rows; and
- persists Apple Weather legal and combined-mark URLs so the native UI can
  render required attribution.

WeatherKit does not require a user data permission prompt. The signed app does
require the Apple Developer WeatherKit capability and the Boolean
`com.apple.developer.weatherkit` entitlement. A typed WeatherKit
`permissionDenied` error becomes an unavailable result, which covers missing
service entitlement without pretending it is a location permission decision.
Other service failures throw a redacted adapter error and preserve the local
cache.

The public WeatherKit error contract does not expose a documented rate-limit
case. Odyssey therefore does not inspect localized messages or private error
codes. The provider-neutral contract supports explicit rate limiting for
synthetic or future supported adapters; unknown WeatherKit failures remain
generic failures until Apple exposes a stable discriminator.

## Attribution rules

Every stored weather snapshot requires provider attribution and an HTTPS legal
page. WeatherKit snapshots also carry the documented combined light/dark Apple
Weather mark URLs. Workshop selects the contrasting mark for the current color
scheme, retains text as a loading/failure fallback, and always presents the
legal source link.

Do not remove, cache-bust, recolor, crop, replace, or hide provider marks to
make a build or screenshot cleaner. Recheck the current WeatherKit attribution
requirements before each production release. If the provider cannot supply
valid attribution, no snapshot is admitted.

## Degraded behavior

- Missing framework: `SystemWeatherAdapter` reports unavailable.
- Missing entitlement/service authorization: unavailable; prior cache remains.
- Network or unknown provider failure: refresh fails; prior cache remains.
- Rate limit from a supported provider: limited; prior cache remains.
- Expired cache: visible but degraded and excluded from fresh planning context.
- Invalid provider row: row rejected and counted; malformed current conditions
  reject the whole snapshot.
- Owner revocation: local record/cursor removed; external service unchanged.
- No foreground place: no provider request; calendar/timezone/manual context
  remains available.

## Validation boundary

Portable Swift tests cover coordinate-free serialization, URL/date/value
validation, synthetic outcomes, mutable replacement, cache preservation,
tamper rejection, local revocation, non-Apple fallback, foreground
Location-to-Weather handoff, denied-location suppression, provider-failure
isolation, and travel across a local-day boundary.

The guarded source was parser-validated and strict-concurrency type-checked
against disposable modules shaped from Apple’s documented public signatures.
That is not an Apple SDK build. No Xcode compile, entitlement signing, live
WeatherKit request, attribution rendering, simulator, device, quota, or
production-terms validation has occurred in this environment.

The owner must follow `docs/deployment/OWNER_HANDOFF.md` to enable WeatherKit on
each environment’s main App ID, regenerate profiles, inspect the signed
entitlement, run only synthetic/public-place checks, verify attribution in both
color schemes, inspect the local database/outbox for coordinate absence, test
offline cache preservation and expiry, and record payload-free evidence.

The Location half of this handoff is specified in
`docs/architecture/location-context.md`.
