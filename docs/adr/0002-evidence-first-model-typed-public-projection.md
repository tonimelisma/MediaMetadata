# 0002. Evidence-first internal model, a fixed typed public projection

- Status: accepted
- Date: 2026-11-28

## Context and problem

A media file holds many competing claims: several capture dates in different clocks, several
locations, orientation in Exif and in a container transform. Consumers need to reason about
them, but most should not have to parse raw tag strings or a candidate list. Serves MM-019 to
MM-025, MM-030 and MM-031.

## Decision drivers

- Never lose the evidence that explains a value (where it was stored, what it said).
- A public contract that is stable, typed and hard to misuse.
- No single "best" date: the local time a picture was taken and the instant it was taken answer
  different questions.

## Considered options

### Flattened properties dictionary (framework style)

- Good: trivial to extend.
- Bad: untyped, keyed by one vendor's names; collapses repeated and conflicting tags.
- Failure modes: a consumer picks the wrong key or a stale duplicate and stores a wrong date.

### Public candidate list with provenance

- Good: nothing hidden.
- Bad: every consumer reimplements the ranking the package knows best; the contract is the
  internal model, so it cannot evolve.
- Failure modes: consumers rank differently and disagree about the same file.

### Internal evidence graph, public fixed typed field set with purpose-named selections

- Good: evidence is kept internally (findings with byte ranges, candidates, diagnostics); the
  public result names each date, location and camera field by its source; `captureWallClock` and
  `captureInstant` give the package's opinion, with the role chosen and published precedence.
- Bad: a new source means a new named field and a contract change.
- Failure modes: a consumer that wants a source the package does not name cannot get it; it
  asks for a field.

## Decision

The third option. The internal model (`ParsedMetadata`, `MetadataFinding`,
`CaptureTimestampCandidate`, ...) never collapses or hides evidence. The public
`MediaMetadataResult` is a fixed, fully typed projection of it: no raw metadata strings, no
candidate arrays, every date its own field, and only purpose-named selections that report their
role and sit beside the fields they choose from.

## Consequences

Consumers get a typed answer and can still apply their own policy over named fields. There is no
`bestDate`. A new field is a public API change (and raises the family's extraction revision,
ADR 0005).

## Confirmation

The consumer API tests (MM-024, MM-025, MM-030) and the golden corpus test (MM-047) pin the public
projection; reviews reject a flattened dictionary or a `bestDate`.

## Retirement proof

Consumers demonstrably needing raw evidence publicly, in numbers a named field cannot serve.

## Reversal plan

Expose a read-only evidence view beside the typed result, never in its place. Cost: a second
public surface to keep stable.
