# Accepted season map prototype

The iPhone Map is the calm 2D cartographic prototype requested by §§18–19 and
Milestone 1.1. It turns one deliberately accepted Season into a regional
orientation view without creating a score, a progress model, or a task list.
It is not the Tomorrow Map and does not predict the next day.

## Authority boundary

`SeasonMapView` reads only the immutable accepted-version cache exposed by the
Workshop snapshot. It filters that history to Season records, selects the
greatest server acceptance sequence, and decodes the cached accepted document.
It never reads a Workshop draft, reviewed draft, queued acceptance command, or
generic sync projection as current orientation.

This means an offline edit can be prepared and reviewed without silently
changing the Map. The new policy appears only after owner acceptance has a
matching immutable server receipt in local history. Decode failure produces an
unavailable state rather than falling back to unreviewed content. Correction
returns to the Workshop; the Map does not mutate normative state.

## Deterministic projection

`SeasonMapProjector` is a portable, model-free transformation from `Season` to
`SeasonMapProjection`. For identical accepted input it returns identical:

- paths in portfolio order, with foreground, middle-ground, or background
  emphasis derived from the direction role;
- protected terrain from foundation details, constraints, and protected
  experiences;
- open horizon from opportunity budgets and protected experiences;
- landmarks from transition triggers and dated direction reviews;
- deliberately dormant areas from dormant directions and explicit non-goals;
- plain-language season rationale, good-week orientation, status, and review
  cadence.

Allocation bands affect line thickness only. They are qualitative attention
bands, not scores. Paths represent sustained directions, never inferred tasks.
The projector does not infer completion, momentum, health, value, or progress.

The current Season contract references directions by identifier but does not
carry accepted Direction titles. Until the Direction service exists, the map
uses stable role labels such as “Primary direction” and preserves the
owner-authored minimum viable commitment or first success signal as detail. It
must not invent a personalized direction name.

## Two equivalent presentations

The default landscape uses SwiftUI `Canvas` for quiet contours, protected
terrain, paths, and landmarks. It has no animation, gesture-only action,
gamified waypoint, or continuous rendering loop. To keep the visual prototype
legible, it draws at most five paths and three landmarks and says when more are
available.

The first-class Plain Language presentation lists every path, boundary,
landmark, protected area, open area, and dormant area. It carries the same
accepted projection and remains the complete alternative when spatial
metaphors, color, small labels, or the display limit are unsuitable. Native
buttons and segmented controls retain correction and presentation actions.

The decorative Canvas is hidden from accessibility. Meaningful labels expose
state and consequence rather than coordinates, and the plain view does not
depend on color. The prototype has no motion, haptic-only signal, drag target,
or celebratory progress language. Dynamic Type, VoiceOver, high contrast, and
differentiate-without-color behavior still require Xcode and device validation.

## Scope and validation boundary

Portable tests verify deterministic role naming, ordering, qualitative
emphasis, protected/open/dormant derivation, landmarks, and the absence of
invented scoring semantics. Linux Swift parser validation covers the iOS source
structure but does not type-check SwiftUI.

This slice completes the plain-language and map prototype deliverable for
Milestone 1.1. It does not complete Tomorrow Map v1, the richer
Metal/SpriteKit experiment, visual theme tokens, four-week emotional-resonance
dogfooding, Xcode accessibility testing, or two-device owner proof.
