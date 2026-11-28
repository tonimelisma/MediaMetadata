# 0003. Timestamp expression is kept apart from absolute instants

- Status: accepted
- Date: 2026-11-28

## Context and problem

Exif writes local wall-clock time, with or without a UTC offset; GPS and QuickTime write UTC; some
formats write both. Collapsing every timestamp into a `Date` invents an instant for a floating
time, or turns a UTC clock into a fake local time. Serves MM-019 to MM-023.

## Decision drivers

- Naming and day grouping need the local time the picture was taken.
- Comparing across time zones needs an instant, and only where one is provable.
- Never read the system time zone or locale in parsing code.

## Considered options

### A bare `Date` per timestamp

- Good: simple.
- Bad: a floating time gets the machine's zone; a UTC time cannot be told from a local one.
- Failure modes: photos land on the wrong day, differently on every machine.

### `CaptureTime` with calendar fields, optional offset, optional instant and a precision

- Good: expression (`localWithOffset`, `localFloating`, `absolute`) and meaning stay separate;
  `captureLocalComponents` is `nil` for absolute times so a UTC clock cannot be mistaken for a
  local one.
- Bad: consumers handle three precisions.
- Failure modes: a consumer that ignores precision may still misuse an instant; the API makes the
  distinction visible.

## Decision

`CaptureTime`, as above. Every emitted time has complete year to second components. Within a role a
capture-local candidate wins over a UTC-anchored one. A GoPro epoch with a recorded time zone
becomes `localWithOffset`; an epoch alone stays `absolute`.

## Consequences

Naming and ordering are correct without a system time zone. Consumers must choose by precision,
or take `captureWallClock` / `captureInstant`.

## Confirmation

`CaptureLocalContractTests` and the timestamp tests (MM-019 to MM-023) fail when a floating time
gains an instant or an absolute time gains local components.

## Retirement proof

None foreseen: the distinction is in the formats themselves.

## Reversal plan

Not planned; collapsing would lose information the formats carry.
