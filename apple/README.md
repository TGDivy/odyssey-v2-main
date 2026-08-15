# Odyssey Apple workspace

The Swift 6.1 package graph is intentionally independent of signing and
personal Apple credentials. `OdysseyDomain` contains pure values and policy
invariants; platform frameworks stay behind adapter protocols in their own
modules.

`OdysseyData` uses the exactly pinned GRDB 7.11.1 package over SQLite. Its
authoritative store enables foreign keys, WAL, full synchronous durability,
strict schema migrations, FTS5, value observation, immutable ledger and
projection history, atomic sync-outbox writes, verified online backup,
projection replay, integrity checks, and complete JSON export. The checked-in
`Package.resolved` makes dependency resolution reproducible.

On a Mac with Swift 6.1 or newer and Xcode installed:

```bash
swift test --package-path apple
../tools/apple/generate-project.sh
```

The SQLite database must live in an Application Support container protected by
the platform data-protection policy. Callers must supply the stable Keychain
device identifier when opening `SQLiteLedgerStore`; opening an existing outbox
under a different identifier fails instead of risking sequence reuse.

The checked-in package graph is the source boundary used by iPhone, Watch,
iPad, Mac, widgets, App Intents, and share-extension targets. `project.yml` is
the reviewed XcodeGen 2.44.1 project source. Tracked configuration contains only
safe placeholders; ignored local xcconfig files supply the owner team, bundle
prefixes, API URLs, and associated domain. Follow
[`docs/deployment/OWNER_HANDOFF.md`](../docs/deployment/OWNER_HANDOFF.md) for the
exact account, entitlement, signing, device, and release gates.
