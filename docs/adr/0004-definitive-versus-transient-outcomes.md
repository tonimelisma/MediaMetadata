# 0004. Definitive and transient outcomes are never confused; parsers fail closed

- Status: accepted
- Date: 2026-11-28

## Context and problem

Consumers cache what the package reports: "this file has no capture date" is stored and never
revisited. A read that failed in the transport (a dropped connection, a camera over MTP, a cloud
placeholder) must not produce that answer. And untrusted, malformed files must never crash the
host. Serves MM-002 to MM-007.

## Decision drivers

- A definitive answer must be about the file, never about the transport.
- Parsing untrusted bytes must be safe and bounded.
- The source protocol must make the two failure kinds impossible to conflate.

## Considered options

### Throwing API, any error aborts

- Good: familiar.
- Bad: one bad tag throws away a whole file's metadata; callers cannot tell structure from
  transport.
- Failure modes: retries on corrupt files forever, or records empty results for unreadable ones.

### A result with an explicit outcome, and a three-outcome source contract

- Good: `.parsed` / `.unsupported` are definitive, `.readFailure` is transient (`shouldRetry`); a
  source returns data, `nil` (the file ends there) or throws (the transport could not answer), and
  anything thrown makes the result `.readFailure`.
- Bad: source authors must honor the contract, including throwing on a short in-bounds read.
- Failure modes: a source that silently returns short data; the reader treats it as a transport
  failure.

## Decision

The second option. Parsers fail closed: they cap reads, recursion and payload sizes, check
integer overflow before offset arithmetic, and return partial results with diagnostics instead of
crashing or discarding the file. Parsing is independent of read granularity.

## Consequences

Consumers can cache definitive results safely and retry transient ones. Every parser carries
robustness and granularity tests.

## Confirmation

`MediaByteSourceTests` (MM-002 to MM-005, MM-007) and `ParserRobustnessTests` (MM-006) fail when
a transport failure reads as definitive or malformed input crashes a parser.

## Retirement proof

None foreseen while consumers persist results.

## Reversal plan

Not planned; consumers depend on the outcome contract.
