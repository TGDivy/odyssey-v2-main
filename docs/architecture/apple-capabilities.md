# Apple capability matrix

Odyssey requests capabilities incrementally and remains useful when any optional
permission is denied. A target receiving an entitlement does not imply standing
permission to use the corresponding data or perform an external action.

| Capability | Targets | Owner setup | Runtime rule | Degraded behavior |
| --- | --- | --- | --- | --- |
| App Groups | iOS, Watch, widgets, intents, share, Mac | Register one group per environment | Store only extension-safe caches and queued commands; only the main app writes SQLite | Direct in-app capture remains available; unavailable extension handoff is reported |
| Sign in with Apple | iOS | Enable on the main App ID; use that bundle ID as the backend audience | Exchange nonce-bound Apple identity tokens only | No cloud sync; local capture remains available |
| HealthKit | iOS, Watch | Enable HealthKit on both identifiers | Ask by data type at the moment of value | Manual/synthetic health context; no blocked capture |
| EventKit | iOS | Add calendar usage descriptions | Read and write permissions are separate | User-entered commitments and imported files |
| Notifications/APNs | iOS | Enable push and upload APNs signing key to backend secret store | Visible delivery remains budgeted and optional | In-app, widget, and local pre-scheduled surfaces |
| Background tasks | iOS | Register refresh and maintenance identifiers | Opportunistic only; never a deadline clock | Foreground reconciliation and server reevaluation |
| Significant location | iOS | Enable location background mode only after owner review | Broad, sparse context; no continuous precise history | Calendar/timezone/manual place context |
| Siri/App Intents | iOS intents | Enable Siri entitlement | Bounded text queues through the App Group; food opens the private in-app ranking surface | Standard in-app capture |
| Widgets/controls | widget extension | Embed and sign with shared group | Render cached state with explicit freshness; generic actions route to private in-app sheets | Main app remains fully usable |
| Watch | watchOS app | Register companion bundle and HealthKit capability | Offline quick actions queue locally | iPhone capture path |
| Associated domains | iOS | Replace placeholder domain and host AASA file | Only verified HTTPS links | Universal links open in browser |
| Photos | iOS | Add usage description | User-selected references only | Archive without photo enrichment |
| Foundation Models | supported Apple targets | No cloud credential; availability-gated | Optional rendering/enrichment, never canonical mutation | Deterministic local or evaluated cloud fallback |

The food HealthKit write path is narrower than the entitlement. It asks from an
explicit food-sheet action for write-only dietary energy, protein, and caffeine
types currently used by the food library. The local occurrence is committed
first and remains authoritative for semantic meaning. HealthKit samples use
stable occurrence/revision metadata, correction replaces only Odyssey-owned samples,
and void removes those owned samples. Alcohol grams are not approximated. The
portable plan/reconciler is tested; Xcode type-checking and physical permission,
sample replacement, revocation, and non-interference evidence remain owner work.

`apple/Config/*.xcconfig` intentionally contains placeholder bundle IDs and
domains. Exact account registration and replacement steps belong in
`docs/deployment/OWNER_HANDOFF.md`.
