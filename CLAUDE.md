# CLAUDE.md

## What this is

MediaMetadata is a Swift-native, framework-neutral library that extracts provenance-preserving
metadata (typed capture dates, location, camera, geometry, video and exposure facts, plus a
definitive-versus-transient outcome) from media file bytes. It ships as a Swift Package Manager
library, depends only on `Foundation`, and builds on macOS 13+, iOS 16+, tvOS 16+, watchOS 9+,
visionOS 1+ and Linux. Swift 6 language mode, XCTest. The consumer docs are `README.md`.

## Working style

- When it is clear what is wanted, do it. Ask only for what only the user can do, or for a real
  product choice nobody has made yet.
- Don't end a turn with a summary announcing the next step, an offer to continue, or a list of
  decisions that block nothing: take the next step.
- Stop only when nothing can move forward without the user, or when what blocks you is
  deliberately protected (a permission, a ruleset, a secret). Then say exactly what is needed.
- Still confirm destructive or irreversible actions outside the normal flow (deleting data,
  rewriting history, changing settings); the normal flow (branch, commit, PR, merge, release) is
  not one of them.

## Product invariants

- The core target `Sources/MediaMetadata` imports `Foundation` and nothing else: no AppKit,
  UIKit, ImageIO, AVFoundation or other platform framework, no third-party dependency.
  ([ADR 0001](docs/adr/0001-foundation-only-core.md))
- Evidence comes first in the internal model: never collapse raw metadata into a flattened
  dictionary or hide the candidate list there. The public result is a fixed, fully typed field
  set derived from it: every date its own named field, no raw metadata strings, no `bestDate`.
  Opinionated selections are purpose-named (`captureWallClock`, `captureInstant`), report the
  role they chose, publish their precedence, and never replace the fields they choose from.
  ([ADR 0002](docs/adr/0002-evidence-first-model-typed-public-projection.md))
- Timestamp expression stays separate from absolute instants: never a bare `Date`, never the
  system time zone or locale in parsing code.
  ([ADR 0003](docs/adr/0003-timestamp-expression-apart-from-instants.md))
- A failure is never reported as definitive: a transport failure is `.readFailure`, never
  `.parsed` with empty fields. Parsers fail closed: cap reads, recursion and payload sizes, check
  integer overflow before offset arithmetic, return partial results with diagnostics, never
  crash. Results never depend on read granularity.
  ([ADR 0004](docs/adr/0004-definitive-versus-transient-outcomes.md))
- The package owns mechanisms over bytes; consumers own policy and cost (chunk sizes, which
  timestamp to trust, when a re-read is worth it). Every change must be justifiable to a second
  consumer who has never heard of the requesting application.
  ([ADR 0005](docs/adr/0005-mechanism-here-policy-in-the-consumer.md))
- Raise `MediaMetadataReader.extractionRevision(for:)` for each family whose already-reported
  values change for the same bytes, or that newly reports a field, and add a row to its table, in
  the same PR. Don't raise it for a family the change does not touch.
  ([ADR 0005](docs/adr/0005-mechanism-here-policy-in-the-consumer.md))
- Never treat a framework- or extension-detected format as truth: the bytes decide.

## Engineering philosophy

- No compatibility shims. When a structure is wrong, replace it and migrate its callers in the
  same change.
- The smallest correct design. Simplicity first; measure before optimizing, never optimize on a
  hunch.
- One owner per fact, per mutation and per side effect. Two places that know the same thing will
  disagree.
- Abstractions only at real boundaries (a process, a network, a storage format, a platform), not
  in anticipation.
- Don't guess and don't fabricate: an unknown API, path, value or result is looked up, measured or
  reported as unknown.
- You own the repository. Nothing is "pre-existing" or someone else's problem, and red CI is never
  waived: it is fixed first.
- Comments and docs describe current behavior and why it is that way, never its history.
- Source-timestamp correctness matters more than broad tag novelty.

## Engineering practices

- Test first. A change in behavior starts with a test that fails without it.
- Every bug, CI failure and review finding gets a regression test, seen failing before the fix;
  quote its red output in the PR.
- The instrumentation flywheel, every increment:
  - Never guess a bug's cause. If the logs and metrics can't explain it, add the instrumentation
    first, so this occurrence or the next one is diagnosable, then fix.
  - Never guess at performance: measure, keep a baseline, optimize, and report before and after.
  - Even when nothing is blocked, review the instrumentation on every path you touched: add what
    was missing, remove what is noise.
- Tests are hermetic: temporary directories and fixtures, never the developer's real data, config
  or accounts.
- Here the instrumentation is the library's own: `readCost` (timings, parser and transport read
  counts, unique bytes, highest offset, whole-file flag) and diagnostics on every partial result.
  A parser change reports read counts before and after.
- XCTest, one test per promoted timestamp authority and per parser path, tagged
  `// Validates: MM-NNN` above the test. Prefer synthetic fixtures; a real camera sample needs
  provenance, rights and a privacy review recorded in `Tests/Fixtures/README.md`, and stays small
  unless it is strictly necessary.
- Every parser family carries a read-granularity test and a malformed-input robustness test.
- Style: the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/),
  4-space indentation, `let` over `var`, `guard` over nested `if`, no force unwraps or force casts
  in production code, explicit access control, functions under about 60 lines, `///` DocC
  comments on public API. `actionlint` any workflow you change.

## Commands

```sh
script/verify                     # everything CI checks: imports guardrail, build, tests,
                                  #   xcodebuild on macOS, process-check (run before every push)
swift build                       # fast compile check
swift test                        # the whole test suite
swift test --filter ExposureTests/testEveryExposureTagIsReported   # one test
script/check-platform-neutral     # the core target imports only Foundation
script/check-local-fixtures.sh    # verify committed fixtures, download the 3 large public ones
script/generate-fixture-goldens.swift   # regenerate ExifTool records (needs exiftool)
script/process-check              # requirements, tests and doc links agree
script/stage start | pre-merge <PR> | post-merge <PR>
```

There is no formatter configured; follow the style above.

Sessions run in two modes. In a cloud session (claude.ai/code, Ubuntu without Swift) the
SessionStart hook in `.claude/settings.json` runs `script/cloud-setup.sh`, which installs the
Swift release CI's Linux job uses (signature-checked, into `/opt/swift-<version>`); update its
default version when CI's `swift:` image moves. On a Mac, `swift test` and `xcodebuild` also run
locally (`script/verify` runs both). Either way CI is the verification: its macOS and Linux jobs
decide. The golden test skips the three large public fixtures unless
`script/check-local-fixtures.sh` fetched them; a limited network must allow the hosts listed in
`Tests/Fixtures/README.md`.

## Where docs live

- `docs/index.md` maps every doc. Requirements live in `docs/requirements.md`: stable IDs, one
  EARS sentence each, current behavior only, each `[verified]` by a test tagged
  `Validates: <ID>` or `unverified: <why>`. Future work lives in GitHub issues, not in docs.
- `docs/architecture.md` says how the code is built and why; `docs/adr/NNNN-title.md` records each
  decision (superseded, never deleted); `docs/lessons.md` holds rules learned and open problems,
  and is pruned when they are resolved.
- `README.md` is for consumers: API, supported formats, a migration note for every release that
  changes behavior. `Tests/Fixtures/README.md` records each real fixture's provenance.
- Update the docs and this file in the same PR as the code they describe: public API, supported
  formats, build steps or guardrails.

## Increment lifecycle

1. **Start**: `script/stage start`. Anything red on main or in the last scheduled run, and any
   unanswered review comment on recent PRs, is fixed before new work. Read the open issues.
2. **Ready**: write the Definition of Ready in the PR body: the problem, requirement IDs or
   issue, acceptance criteria, what is out of scope.
3. **Test first**, then implement with the instrumentation flywheel.
4. **Verify** with the one verify command; it must be green before pushing.
5. **Docs** (requirements, architecture, ADRs, lessons, this file) in the same PR.
6. **Land**: PR, wait for `CI gate`, squash-merge, which releases (see Git, CI and PRs).
7. **Report**: after the merge, one PR comment with the Definition of Done checklist and the final
   increment report (below).

A plan that spans several increments lives in a GitHub tracking issue with a checklist, never in
a file. Never committed: per-PR report or readiness files, session state or resume files, ledgers
of merged PRs. That information belongs in the PR and its comments.

## Git, CI and PRs

- One branch per increment, cut from a fresh `origin/main`, named `feat/`, `fix/`, `docs/`,
  `chore/`, `refactor/` or `perf/` plus a short topic. Never reuse a branch after its PR merged;
  never name a branch for the tool that wrote it.
- Every change lands through a PR whose body fills `.github/pull_request_template.md`. CI checks
  the body, and that a PR titled `fix...` changes a test.
- `CI gate` is the one required check: a job that needs every other job. Wait for it
  (`script/stage pre-merge <PR>`), and fix every failure; never bypass it.
- Squash-merge as soon as `CI gate` is green, without asking: in a cloud session with
  `gh api -X PUT repos/<owner>/<repo>/pulls/<N>/merge -f merge_method=squash -f sha=<head sha>`
  (`script/stage post-merge <PR>` does this); locally with `gh pr merge --auto --squash`.
- Merging to main releases; nobody tags or publishes by hand.
- The cloud sessions' GitHub proxy refuses tag pushes, branch deletion and GraphQL: use the REST
  API (`gh api`), and leave branch deletion to GitHub's delete-on-merge and the branch-cleanup
  workflow.
- Commit messages: an imperative subject saying what changed; the body says why.
- CI (`.github/workflows/ci.yml`, workflow `CI`) runs on every PR (including description edits),
  every push to main, weekly on main and by hand: `macOS` runs `script/verify` (build, `swift
  test`, `xcodebuild … test`, process-check), `Linux` builds and tests in the `swift:6.0`
  container, `guardrail` runs `script/check-platform-neutral`, `process` runs process-check and
  pr-check, and `CI gate` needs them all.
- Release (`.github/workflows/release.yml`, a library release: tag and notes, nothing built):
  when CI succeeds on a push to main, it tags that commit with the next patch in the series
  `VERSION` names (`0.9` → `0.9.7` after `0.9.6`; no `v` prefix) and creates a GitHub release
  with generated notes. A commit already tagged is skipped. Start a new minor or major series by
  editing the one line in `VERSION` (pre-1.0, a breaking public-API change starts the next
  minor); its first release is `X.Y.0`. The README's `from:` pin is documentation of a recent
  version and is not bumped per release. Retry with `workflow_dispatch` on main.

## Privacy review

Before every commit, read your own staged diff (`git diff --cached`) and remove anything private
about the maintainer, their family or their computers: people's names, addresses, personal email
addresses and accounts, hostnames, home-directory paths, IP addresses, tenant, client or vault
IDs, real personal documents or photos. Use neutral stand-ins in tests and examples. There is no
list of private terms to check against: judge the diff.

## Definition of Done

An increment is done when every line holds; the final report marks each ✅ or ❌ with evidence:

- [ ] Start stage clean: main CI, the last scheduled run and recent review comments were green or
      fixed first.
- [ ] Tests first; the regression test's red output before the fix is quoted.
- [ ] The verify command is green, and CI is green on the final commit.
- [ ] Traceability and doc checks (`script/process-check`, `script/pr-check`) are green.
- [ ] Docs and CLAUDE.md are updated in the same PR.
- [ ] Instrumentation reviewed on touched paths: what was added, what removed, or why it is
      adequate.
- [ ] Privacy review done on every commit's staged diff.
- [ ] Every review thread is answered or resolved.
- [ ] Merged; main CI green; the release it produced is linked.
- [ ] Clean up: only main and open PRs' branches remain on the remote; the working tree is clean.

### Final increment report

One PR comment after the merge, with these parts:

1. **Done / not done**: what the increment delivered, and anything left out.
2. **Definition of Ready**: as written, and whether it held.
3. **Requirements, ADRs and docs**: IDs added, changed or retired; ADRs; docs touched.
4. **Design decisions**: each with the alternatives considered and why they lost.
5. **Verification evidence**: commands, CI run links and durations, release link.
6. **Regression test**: name and red output before the fix (or "no bug fixed").
7. **Diagnosis**: for a bug, the root cause and how it was established.
8. **Instrumentation**: added, removed, and gaps still open.
9. **Performance**: before and after numbers, or "not touched".
10. **Privacy review**: done on every commit; anything removed.
11. **Smells**: what looked wrong but was out of scope.
12. **Follow-ups**: each filed as an issue, linked.
13. **Definition of Done**: the checklist above, each line ✅ or ❌ with evidence.
