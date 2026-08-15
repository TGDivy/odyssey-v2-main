# Security Policy

Odyssey processes highly sensitive personal data. Security reports must not be
filed in public issue trackers and must never include production payloads,
tokens, exports, screenshots, or model traces containing personal information.

## Reporting

Report suspected vulnerabilities privately to the repository owner. Include:

- the affected commit and environment;
- a payload-free reproduction or synthetic fixture;
- expected and observed behavior;
- likely impact and whether credentials may be exposed;
- immediate containment already performed.

If no private reporting channel is configured, contact the owner directly
before sharing details or opening an issue.

## Immediate response

For a suspected compromise:

1. pause proactive intelligence and outbound integrations;
2. revoke affected provider, OAuth, device, and deployment credentials;
3. preserve payload-safe logs and trace identifiers;
4. restrict production access;
5. follow `docs/runbooks/incident-response.md`;
6. verify backup integrity before any destructive remediation.

Never wipe a device or database as a routine recovery step. Unsynced operations
may exist on another device and must be reconciled through the incident process.

## Supported versions

Until the first production release, only the latest commit on `main` receives
security fixes. Release support policy will be recorded before external use.

