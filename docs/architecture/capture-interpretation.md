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

## Owner review contract

`CaptureInterpretationReviewDraft` carries a stable review-version ID, the exact
interpretation version reviewed, the expected capture revision, and one of
three explicit dispositions: accepted, corrected, or dismissed. Corrected
reviews carry bounded replacement values; accepted and dismissed reviews
cannot smuggle replacements into the ceremony.

The resulting `CaptureInterpretationVersion` has explicit
`supersedesInterpretationVersionID` lineage, owner-review disposition, and an
optional bounded note. Accepted and corrected results remain interpreted;
dismissal is a distinct terminal meaning and cannot retain proposed fields.
The cross-stack contract rejects self-supersession, unbound review metadata,
empty corrections, and incoherent status/disposition combinations.

This slice defines the append-only semantics and registered
`capture.interpretation_reviewed.v1` event. Durable review execution and the
Archive correction surface are implemented in the following slices rather than
overloading analytics feedback.

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

## Durable asynchronous execution

`CaptureInterpretationService` loads the current local capture projection,
invokes an adapter after the original write has returned, then re-reads the
capture before committing. A successful result atomically appends
`capture.interpreted.v1`, advances the capture projection by one revision, and
queues the complete revised document for generic sync. The original payload,
content hash, capture time, context, and attachments are copied unchanged.

The service validates that every proposed source reference belongs to the same
capture or one of its declared attachments. Foreign references fail before any
ledger, projection, or outbox mutation. Identical capture/interpreter/version
runs are idempotent, and concurrent callers share one in-flight adapter task so
that a provider is not invoked twice accidentally.

Deferral and adapter failure leave the capture pending without writing a false
interpretation. Pending captures are discoverable oldest first. The iPhone
schedules interpretation only after durable capture success, rescans pending
captures at bootstrap and opportunistic background refresh, and schedules sync
independently so neither networking nor interpretation delays the capture
receipt. A crash before the atomic derivative commit therefore returns to the
pending state on the next run; there is no durable half-interpreted state.

This slice does not claim provider-backed interpretation, automatic provider
retry policy, media transcription, normalized observations, or correction UI.
Those remain later Milestone 1.2 layers.
