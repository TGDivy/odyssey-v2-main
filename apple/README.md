# Odyssey Apple workspace

The Swift 6 package graph is intentionally independent of signing and personal
Apple credentials. `OdysseyDomain` contains pure values and policy invariants;
platform frameworks stay behind adapter protocols in their own modules.

On a Mac with Swift 6 and Xcode installed:

```bash
swift test --package-path apple
```

The checked-in package graph is the source boundary used by iPhone, Watch,
iPad, Mac, widgets, App Intents, and share-extension targets. Project generation,
bundle identifiers, entitlements, and account setup are added separately so no
development build can accidentally inherit production capabilities.

