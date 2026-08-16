# Capture interpretation boundary

Odyssey separates an immutable original capture from every derived
interpretation. The immediate local write remains the only synchronous capture
requirement; classification, extraction, entity links, and clarification are
replaceable versioned derivatives.

## Version contract

`CaptureInterpretationVersion` aligns the native capture projection with the
Appendix A.4 and generated backend schema shape. A version records a stable
interpreter identifier and version, creation time, terminal interpretation
status, proposed fields, and source-span references. Pending and processing are
capture workflow states, not durable interpretation results.

Every proposed field is a `CaptureInterpretedField` containing both its typed
JSON value and at least one source reference. The version-level source list is
derived from those fields rather than supplied independently. This prevents an
adapter from producing an apparently precise field with no link to the original
capture. Proposed fields do not become observations or canonical facts through
interpretation alone; material acceptance and correction remain separate.

## Adapter boundary

`CaptureInterpreting` is provider-neutral and asynchronous. It receives the
immutable payload, capture time, initial context, and attachment references,
and returns either a source-linked proposal or an explicit stable deferral.
Provider text, private errors, credentials, and model-specific response objects
do not enter the capture contract.

`DeterministicCaptureInterpreter` is the first conservative fallback. It:

- recognizes only owner-written prefixes such as `food:`, `caffeine:`,
  `decision:`, or `symptom:`;
- treats unlabeled text as an unstructured note instead of guessing;
- marks explicit domain labels for later owner review;
- defers audio, image, and file references until a content-capable adapter is
  available;
- never creates an observation, recommendation, score, or task.

This contract slice does not yet claim durable asynchronous execution,
automatic retry, media transcription, normalized observations, or correction
UI. Those remain the next Milestone 1.2 layers.
