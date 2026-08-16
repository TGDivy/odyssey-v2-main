# Apple capability matrix

Odyssey requests capabilities incrementally and remains useful when any optional
permission is denied. A target receiving an entitlement does not imply standing
permission to use the corresponding data or perform an external action.

| Capability | Targets | Owner setup | Runtime rule | Degraded behavior |
| --- | --- | --- | --- | --- |
| App Groups | iOS, Watch, widgets, intents, share, Mac | Register one group per environment | Store only extension-safe caches and queued commands; only the main app writes SQLite | Direct in-app capture remains available; unavailable extension handoff is reported |
| Sign in with Apple | iOS | Enable on the main App ID; use that bundle ID as the backend audience | Exchange nonce-bound Apple identity tokens only | No cloud sync; local capture remains available |
| HealthKit | iOS, Watch | Enable HealthKit on both identifiers | Ask by data type at the moment of value; anchored reads and Odyssey-owned writes stay separate | Existing local context, manual context, and all non-Health workflows remain available |
| EventKit | iOS | Add calendar usage descriptions | Full access is required for the bounded read mirror; write-only is never treated as readable | Prior local mirror, user-entered commitments, and imported files remain available |
| WeatherKit | iOS | Enable WeatherKit on the main App ID and sign `com.apple.developer.weatherkit` | Fetch only from a transient foreground broad-place query; persist provider expiry and required attribution, never coordinates | Prior unexpired local snapshot, calendar/timezone/manual context, or no weather context |
| Core Location (when in use) | iOS | Keep the reviewed usage description; no portal capability is required | Prompt only from the explicit owner action, request one broad foreground fix, discard coordinates after the immediate Weather handoff | Prior broad place, calendar/timezone/manual context, and all non-Location workflows |
| Notifications/APNs | iOS | Enable push and upload APNs signing key to backend secret store | Visible delivery remains budgeted and optional | In-app, widget, and local pre-scheduled surfaces |
| Background tasks | iOS | Register refresh and maintenance identifiers | Opportunistic only; never a deadline clock | Foreground reconciliation and server reevaluation |
| Significant/background Location | None | Do not enable the location background mode | Unsupported; no standard updates, visits, regions, or significant-change monitoring | Explicit foreground broad-place refresh only |
| Siri/App Intents | iOS intents | Enable Siri entitlement | Bounded text queues through the App Group; food opens the private in-app ranking surface | Standard in-app capture |
| Widgets/controls | widget extension | Embed and sign with shared group | Render cached state with explicit freshness; generic actions route to private in-app sheets | Main app remains fully usable |
| Watch | watchOS app | Register companion bundle and HealthKit capability | Text/food commands persist locally and use receipt-bound WatchConnectivity; ranked presets expire | Pending commands remain on Watch; full iPhone capture path remains available |
| Associated domains | iOS | Replace placeholder domain and host AASA file | Only verified HTTPS links | Universal links open in browser |
| Photos | iOS | Add usage description | User-selected references only | Archive without photo enrichment |
| Foundation Models | supported Apple targets | No cloud credential; availability-gated | Optional rendering/enrichment, never canonical mutation | Deterministic local or evaluated cloud fallback |

Workshop derives an eight-entry runtime matrix for Health sample reads, Health
nutrient writes, calendar reads, calendar writes, current weather, weather
forecasts, foreground Location, and significant/background Location. Each row
reports adapter availability separately from permission. Calendar write and
significant/background Location are always `disabledByPolicy`; they are never
inferred as available from an OS version or entitlement. A separate connector
health catalog aggregates Health, Calendar, Weather, and Location freshness,
contribution, rejection, rate-limit, schema, and operational state without
rendering imported values or coordinates.

The food HealthKit write path is narrower than the entitlement. It asks from an
explicit food-sheet action for write-only dietary energy, protein, and caffeine
types currently used by the food library. The local occurrence is committed
first and remains authoritative for semantic meaning. HealthKit samples use
stable occurrence/revision metadata, correction replaces only Odyssey-owned samples,
and void removes those owned samples. Alcohol grams are not approximated. The
portable plan/reconciler is tested; Xcode type-checking and physical permission,
sample replacement, revocation, and non-interference evidence remain owner work.

The Health context read path supports workouts, heart rate, resting heart rate,
sleep analysis, body mass, and active energy. The guarded Apple adapter uses one
secure-coded HealthKit anchor per sample type and retains source bundle/name,
source version, product type, and operating-system version when supplied. Apple
does not reveal per-type read authorization, so an `unnecessary` authorization
request status is represented as `partial`, never as proof that every requested
type was granted. Query authorization errors become explicit denied outcomes.

`HealthImportCoordinator` loads the per-type anchor before every query, converts
valid samples to deterministic sorted-key JSON, and atomically applies inserted
records, source deletions, and the next anchor to the current schema-v5 local
store. Schema v4 introduced these integration-mirror tables; the persistence
layer computes and verifies each document SHA-256.
HealthKit UUIDs are immutable source identities: exact replay is counted as a
duplicate; a conflicting document is rejected rather than overwriting source
history. The next anchor still commits after a conflict so a poison page cannot
stall future imports. Adapter-level parse rejections, same-page conflicts,
store-level duplicates, deletions, and rejected records remain explicit in the
receipt. None of these local records is added to the sync outbox.

Workshop exposes a privacy-safe overview rather than sample values: capability,
permission, supported types, local count, last successful import, newest source
timestamp, lag, rejected/quarantined count, schema status, rate-limit status,
anchored-type count, observer-registration state, and the statement that this
connector contributes only approved Health context. Permission denial does not
erase prior local context. **Remove Local Health Mirror** first stops change
observation and then deletes every local Health record and anchor while leaving
HealthKit samples and system permission untouched. Launch and opportunistic app
refresh resume Health import only when a durable per-kind cursor proves prior
owner activation; local revocation therefore cannot silently repopulate itself.

The guarded Apple adapter registers one `HKObserverQuery` and immediate
background-delivery request per supported sample type after a successful import
with durable owner activation. A callback advances only the signaled type through the same
anchored coordinator, and calls the HealthKit completion handler only after that
async import callback returns. Registration failure is exposed as degraded while
owner-requested and opportunistic app-refresh imports remain usable. The
portable observation seam, scoped callback behavior, durable activation policy,
and revocation ordering are tested; the guarded source is parser-validated and
strict-concurrency type-checked against disposable modules shaped from public
signatures. Xcode compilation and physical authorization, delivery,
deduplication, deletion, suspension, and relaunch evidence remain owner work.

The EventKit read path and its local-only bounded reconciliation are specified in
`docs/architecture/calendar-context.md`. It is independent from any future
write-only event-creation flow.

The WeatherKit path stores one mutable broad-place snapshot with current,
hourly, and daily canonical SI values, explicit source/request/expiry clocks,
and HTTPS provider attribution/combined-mark URLs. Coordinates and accuracy are
transient non-`Codable` query inputs and never enter the local mirror or sync
outbox. Unavailable, rate-limited, unknown-service, and expired-cache states are
visible; failures preserve prior local context. The checked-in iOS entitlement
still requires the owner to enable WeatherKit on every main App ID and
regenerate profiles. The guarded source has only parser and public-signature
stub validation here; Xcode, signing, live service, attribution, quota, and
device proof remain owner work. See `docs/architecture/weather-context.md`.

The Core Location path stores one mutable broad-place record with precision,
time zone, capture time, and expiry. Coordinates and horizontal accuracy exist
only in a non-`Codable` transient fix and disappear after the immediate Weather
handoff. Location denial suppresses Weather; Weather failure preserves the newly
acquired broad place and any prior forecast according to each connector's own
rules. Launch and background tasks never acquire Location or refresh Weather.
Workshop exposes explicit authorization, refresh, health, and local revocation
controls without showing coordinates. The app declares only when-in-use usage
and intentionally omits the location background mode. Named-zone travel fixtures
verify local-day reassignment without 24-hour arithmetic. See
`docs/architecture/location-context.md`.

`apple/Config/*.xcconfig` intentionally contains placeholder bundle IDs and
domains. Exact account registration and replacement steps belong in
`docs/deployment/OWNER_HANDOFF.md`.
