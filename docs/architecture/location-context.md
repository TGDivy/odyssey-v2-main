# Broad location context boundary

Odyssey uses Location only to resolve an owner-requested, current broad place.
It is not a location-history system, a visit tracker, a geofence engine, or an
always-on background service. The current implementation deliberately supports
one foreground request on iOS and visionOS and reports unavailable everywhere
else.

## Portable contract

`TransientLocationFix` carries latitude, longitude, horizontal accuracy, and a
validated `BroadLocationContext` only in memory. It deliberately does not
conform to `Codable`. The persisted broad context contains only:

- an opaque application-defined place identifier;
- an optional locality or administrative-area display name;
- an IANA time-zone identifier;
- locality, administrative-area, or time-zone-only precision; and
- capture and expiry clocks.

The provider result distinguishes acquired, permission-denied, restricted,
unavailable, insufficient-accuracy, and no-fix outcomes. A non-acquired result
cannot carry a fix. Every identifier, text, time zone, coordinate, accuracy,
date, expiry, result shape, and rejection count is validated at construction;
persisted documents and cursors are validated again when decoded.

`LocalDate(containing:in:)` derives civil dates with a named Gregorian calendar
and the captured IANA time zone. Travel tests prove that one UTC instant can
belong to different local dates without adding or subtracting a fixed 24-hour
duration.

## Local-only mirror

`LocationContextCoordinator` uses connector `location` and stream
`broad_place`. It stores at most one mutable record named `current`. A later
successful place replaces the earlier record instead of building history.
Permission, accuracy, provider, or no-fix failures update bounded attempt
diagnostics while preserving the prior broad context.

The cursor contains only last attempt, last successful refresh, outcome, and
rejected count. It never contains coordinates, accuracy, or the newly requested
place. The current schema-v5 store hashes the document; schema v4 introduced
the integration-mirror tables. Location never creates a ledger event or
sync-outbox operation.

Explicit **Remove Local Broad-Place Context** stops any pending request and
clears the local record and cursor. It does not change system permission. A
subsequent refresh requires another explicit owner action.

## Guarded Core Location adapter

`CoreLocationAdapter` compiles only when Core Location is available on iOS or
visionOS. It is isolated to the main actor and:

1. inspects current when-in-use authorization without prompting;
2. requests when-in-use authorization only from the explicit Workshop action;
3. calls `requestLocation()` once for an explicit refresh;
4. rejects fixes older than five minutes or less accurate than 50 kilometres;
5. requests three-kilometre desired accuracy rather than navigation precision;
6. reverse-geocodes only locality, administrative area, and time zone;
7. emits an opaque stable FNV-1a identifier from those broad fields; and
8. expires the broad context after two hours.

The adapter never starts standard updates, significant-change monitoring,
visits, regions, or background location. `UIBackgroundModes` intentionally has
no `location` entry. Significant/background Location remains unsupported until
a separately reviewed feature, owner rationale, battery/privacy analysis,
entitlement change, and device test exist.

## Foreground Weather handoff

The Workshop action **Refresh Broad Place and Weather** invokes
`ForegroundContextRefreshCoordinator`. It first commits only the broad place.
If and only if the result is acquired, the coordinator constructs a transient
`WeatherQueryLocation`, immediately calls the Weather mirror, and returns a
receipt containing outcomes but no fix or coordinates. Denied, restricted,
unavailable, inaccurate, and no-fix outcomes make no Weather request.

A Weather provider failure does not undo the successfully acquired broad place.
Weather and Location keep independent local health and revocation controls.
Bootstrap, app-refresh tasks, widgets, Watch commands, and sync never acquire
Location or refresh Weather. No coordinate is logged, rendered, encoded, added
to integration health, or placed in the sync outbox.

## Owner-facing integration health

Workshop exposes capability, when-in-use permission, one-shot support, explicit
absence of continuous/background use, broad display name, precision, time zone,
capture/expiry/freshness, last attempt/outcome, source lag, rejected count,
schema status, and local revocation. It never displays coordinates or accuracy.
The integration-health contribution is `broad_foreground_place`.

Useful degraded behavior is mandatory:

- denied/restricted permission: prior broad place remains; all other workflows
  continue;
- no or inaccurate fix: prior broad place remains and Weather is not queried;
- missing framework/platform: capability and permission report unavailable;
- reverse-geocode/provider failure: no newly requested place is persisted;
- expired broad place: visible as degraded, not silently fresh; and
- local revocation: local record/cursor disappear while system permission is
  unchanged.

## Validation boundary

Portable Swift tests cover contract validation, coordinate-free round trips,
single-record replacement, denial preservation, local revocation, unavailable
fallback, Location-to-Weather handoff, provider failure isolation, storage-key
inspection for coordinate absence, and travel across local-day boundaries.

The guarded Apple branch has been parser-validated and strict-concurrency
type-checked against disposable modules shaped from documented public
signatures. That is not an Apple SDK build. No Xcode compile, signed entitlement
inspection, authorization prompt, reverse geocode, simulated/physical location,
WeatherKit request, battery behavior, or device-container inspection has run in
this environment. Follow `docs/deployment/OWNER_HANDOFF.md` and retain only
payload-free synthetic evidence.
