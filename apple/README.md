# Odyssey Apple workspace

The Swift 6 package graph is intentionally independent of signing and personal
Apple credentials. `OdysseyDomain` contains pure values and policy invariants;
platform frameworks stay behind adapter protocols in their own modules.

On a Mac with Swift 6 and Xcode installed:

```bash
swift test --package-path apple
../tools/apple/generate-project.sh
```

The checked-in package graph is the source boundary used by iPhone, Watch,
iPad, Mac, widgets, App Intents, and share-extension targets. `project.yml` is
the reviewed XcodeGen 2.44.1 project source. Tracked configuration contains only
safe placeholders; ignored local xcconfig files supply the owner team, bundle
prefixes, API URLs, and associated domain. Follow
[`docs/deployment/OWNER_HANDOFF.md`](../docs/deployment/OWNER_HANDOFF.md) for the
exact account, entitlement, signing, device, and release gates.
