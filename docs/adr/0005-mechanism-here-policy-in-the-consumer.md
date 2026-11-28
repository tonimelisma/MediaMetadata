# 0005. The package owns mechanisms over bytes; consumers own policy and cost

- Status: accepted
- Date: 2026-11-28

## Context and problem

Requests arrive from one consumer at a time: buffer remote reads, return a RAW's preview, tell me
when my stored rows are stale. Each is partly about bytes (the package's competence) and partly
about the consumer's transport, latency and storage (which the package cannot see). Serves
MM-008 to MM-011, MM-045 and MM-046.

## Decision drivers

- Every change must be justifiable to a second consumer who has never heard of the requester.
- Container knowledge lives here, not duplicated in each consumer.
- Costs the package cannot see (latency, download price, cache size) are the consumer's numbers.

## Considered options

### Package decides policy too (sizes, retries, when to re-read)

- Good: one-stop for the first consumer.
- Bad: wrong numbers for every other transport; transport lifecycle leaks into the library.
- Failure modes: a cache sized for local disks thrashes over MTP; a forced re-read downloads a
  cloud library.

### Mechanism here, numbers and decisions in the consumer

- Good: the package offers the internal read buffer, `CachingByteSource` with a consumer-chosen
  chunk size, preview *descriptors* (range, declared size, encoding) never decoded or read, and a
  per-family `extractionRevision` that says when a re-read may report more; the consumer decides
  sizes, fetches and when re-reading is worth its bytes.
- Bad: consumers write a little glue.
- Failure modes: a consumer ignores the revision and keeps stale rows; that is its choice, made
  visible.

## Decision

The second option. The revision is per container family, and rises for a corrected value or a
newly reported field, because a stored row cannot tell "the file has none" from "the parser did
not look", and one global number would make every JPEG look stale for a HEIF fix.

## Consequences

Remote consumers get cheap reads without the package knowing their transport. Every change that
alters a family's output must raise that family's revision and only that one.

## Confirmation

`MediaByteSourceTests` (MM-008 to MM-010, MM-045) and `RawAndFileTypeTests` (MM-046:
`testRevisionsMoveOnlyForTheFamiliesThatChanged`) pin the mechanisms and the revision table;
CLAUDE.md requires a revision bump in the same PR as an output change.

## Retirement proof

A capability whose number or decision the package can derive from bytes alone, shown for at
least two consumers.

## Reversal plan

Move a policy into the package behind a parameter with the current behavior as its default.
Cost: one more public knob.
