# 0001. The core target imports Foundation and nothing else

- Status: accepted
- Date: 2026-11-28

## Context and problem

MediaMetadata reads metadata from media bytes for any Swift consumer: an Apple app, a CLI, a
Linux ingest service, tests without a display. Apple's ImageIO and AVFoundation already read much
of the same metadata, and reaching for them for "just this one case" is always tempting. Serves
MM-001 and MM-048.

## Decision drivers

- The package must build and behave the same on every Swift platform, Linux included.
- The model must start from bytes and container structure, not from a framework's key names or
  its idea of the file's format.
- A capability that needs more than bytes is usually consumer policy in disguise.

## Considered options

### Foundation only, every parser written over bytes

- Good: builds anywhere Swift runs; results are the package's own, testable byte for byte; a
  missing framework value can never be mistaken for a missing tag.
- Bad: every container and tag format is parsed here, by hand.
- Failure modes: a parser bug is the package's to find; the golden corpus (MM-047) and the
  robustness tests (MM-006) catch them.

### Use platform frameworks where available, own parsers elsewhere

- Good: less code on Apple platforms.
- Bad: two code paths whose answers differ per platform; Linux gets the lesser one; framework
  key names leak into the schema.
- Failure modes: the same file reports different dates on macOS and Linux, and nobody notices
  until a consumer's library is wrong.

## Decision

Foundation only. `Sources/MediaMetadata` imports `Foundation` and no other module, and has no
third-party dependency. If a capability cannot be expressed in Foundation over bytes, it belongs
to the consumer (see the Consumer Boundary in [architecture.md](../architecture.md)).

## Consequences

The package runs on Linux, in a CLI, in a server and in tests. Decoding pixels, thumbnails and
transcoding stay non-goals. Adding a format means writing its parser.

## Confirmation

`script/check-platform-neutral` (MM-001) fails when the core target imports any module but
Foundation; `script/verify` and CI's guardrail job run it. CI's Linux job builds and tests the
package in the `swift:6.0` container.

## Retirement proof

A capability the package must own that cannot be written over bytes in Foundation, shown by a
second consumer who needs it, and a way to keep Linux behavior identical.

## Reversal plan

Add a separate, platform-specific target that depends on the core one, never imports into the
core target. Cost: a second target and its tests; the core stays as it is.
