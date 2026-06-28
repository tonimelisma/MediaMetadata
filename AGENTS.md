# Agent Instructions for MediaMetadata

This file guides AI agents working on the MediaMetadata Swift package.
Read it at the start of every task and follow its conventions unless the user explicitly overrides them.

## Project Overview

MediaMetadata is a Swift-native, framework-neutral library for extracting
provenance-preserving metadata from media file bytes. It is distributed as a
Swift Package Manager (SPM) library and depends only on `Foundation`.

## Platforms

- macOS 13+
- iOS 16+
- tvOS 16+
- watchOS 9+
- visionOS 1+
- Linux (where Swift toolchain is available)

## Project Structure

```text
Sources/
  MediaMetadata/       # Runtime parser target
Tests/
  MediaMetadataTests/  # XCTest target with synthetic fixtures
Package.swift          # SPM manifest
README.md              # Consumer-facing documentation
ARCHITECTURE.md        # Design contract, non-goals, guardrails
LICENSE                # MIT
```

## Build, Test, and Verify

Use these commands unless the task specifically requires something else:

```sh
swift build
swift test
```

For macOS-specific validation you may also run:

```sh
xcodebuild -scheme MediaMetadata -destination 'platform=macOS' test
```

## Code Style

- Follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).
- Use 4-space indentation.
- Prefer `let` over `var`; prefer `guard` over deeply nested `if`.
- Avoid force unwraps (`!`) and force casts (`as!`) in production code.
- Use explicit access control (`private`, `internal`, `public`) intentionally.
- Keep functions focused and under ~60 lines when possible.
- Use `///` DocC-style comments for public APIs.

## Architecture Principles

- The core target must remain platform-neutral. Do not import AppKit, UIKit,
  ImageIO, or AVFoundation in `Sources/MediaMetadata/`.
- Parsers must fail closed: cap reads, cap recursion, check integer overflow,
  and return partial results with diagnostics instead of crashing.
- Evidence comes first in the **internal** model: do not collapse raw metadata
  into a flattened dictionary or hide the candidate list there. The **public**
  contract is intentionally a fixed, fully typed field set derived from that
  evidence (see `MediaMetadataResult`); it exposes every date as its own named
  field rather than a candidate array, and never returns raw metadata strings.
- Preserve timestamp expression separately from absolute instants.

## Testing Conventions

- Use `XCTest`.
- Prefer synthetic fixtures. When real camera samples are necessary, document
  provenance, privacy review, and licensing in the fixture record.
- Add a test for every promoted timestamp authority and every parser path.
- Keep fixtures small unless a real camera sample is strictly necessary.

## Documentation

- Keep `README.md` consumer-focused.
- Keep architectural design intent in `ARCHITECTURE.md`.
- Update the relevant doc file when you change public API, supported formats,
  build steps, or engineering guardrails.

## Definition of Done (DOD)

Before considering any increment complete, the agent must execute the following
steps in order. Each step must be reported with a ✅ (green) or ❌ (red) status
in the final completion report.

### 1. Verify the working state

- [ ] Run `git status` and note all modified, staged, and untracked files.
- [ ] Run `git diff --stat` to confirm the scope of changes matches the task.
- [ ] If unrelated changes are present, stop and ask the user how to proceed.

### 2. Run the full test suite

- [ ] Run `swift build` and confirm it succeeds.
- [ ] Run `swift test` and confirm all tests pass.
- [ ] If fixture-based or golden tests exist, run them explicitly and confirm
      they pass.
- [ ] If any test fails, fix it before proceeding. Do not ignore failures.

### 3. Review changes for quality

- [ ] Inspect `git diff` for accidental edits, secrets, or debug code.
- [ ] Confirm no force unwraps were introduced unless unavoidable and documented.
- [ ] Confirm platform-specific frameworks were not added to the core target.
- [ ] Confirm new public API has DocC-style comments.

### 4. Commit

- [ ] Stage only the files intended for this increment.
- [ ] Write a concise, imperative commit message that matches repo style,
      e.g. `Add HEIF EXIF item-location parser` or `Fix RIFF list depth guard`.
- [ ] Do not commit secrets, temporary files, or unrelated changes.

### 5. Push and open a pull request

- [ ] Push the branch to the remote.
- [ ] Open a pull request with a clear title and description summarizing the
      changes.
- [ ] If CI is configured, wait for checks to pass. If checks fail, address them.
- [ ] If CI is not configured, note this in the completion report.

### 6. Ensure the code reaches `main`

- [ ] Merge the pull request once it is approved and checks pass.
- [ ] If merge is blocked by required reviews or failing checks, report the
      blocker and stop. Do not bypass protections.
- [ ] After merge, verify `main` on the remote contains the merged commit,
      e.g. `git fetch origin && git log origin/main --oneline -5`.

### 7. Release a new version

- [ ] Once `main` is healthy, choose the next semantic version. Pre-1.0, a
      breaking public-API change bumps the minor (e.g. `0.1.0` → `0.2.0`);
      backward-compatible changes bump the patch.
- [ ] Update any user-facing version references in docs (e.g. the README install
      snippet) to the new version.
- [ ] Tag the merged `main` commit, matching the existing tag style
      (`git tag X.Y.Z` — current tags have no `v` prefix), and push the tag.
- [ ] Create a GitHub release for the tag with notes summarizing the
      user-visible changes (`gh release create X.Y.Z`).
- [ ] Confirm the release and tag are visible on the remote.

### 8. Preserve all work

- [ ] Before deleting any branch, worktree, or stash, confirm its commits are
      reachable from `origin/main` or another protected branch.
- [ ] Never delete unmerged work unless the user explicitly confirms it is
      disposable.
- [ ] Never drop stashes or untracked files that contain user work.

### 9. Clean up agent-created artifacts

After the merged commit is confirmed on `origin/main`:

- [ ] Delete the local feature branch.
- [ ] Delete the remote feature branch if one was pushed.
- [ ] Remove any worktrees created by the agent.
- [ ] List any remaining dangling branches, stashes, or worktrees in the final
      report so the user can decide what to do with them.

### 10. Final verification

- [ ] Run `swift build` and `swift test` on `main` after merge to confirm the
      merged state is healthy.
- [ ] Run `git status` to confirm the working tree is clean.

## Completion Report Template

After finishing an increment, produce a report in this exact format:

```markdown
## Completion Report

### DOD Status

| Step | Description | Status |
|---|---|---|
| 1 | Verify working state | ✅ / ❌ |
| 2 | Run full test suite | ✅ / ❌ |
| 3 | Review changes for quality | ✅ / ❌ |
| 4 | Commit | ✅ / ❌ |
| 5 | Push and open PR | ✅ / ❌ |
| 6 | Ensure code reaches main | ✅ / ❌ |
| 7 | Release a new version | ✅ / ❌ |
| 8 | Preserve all work | ✅ / ❌ |
| 9 | Clean up agent artifacts | ✅ / ❌ |
| 10 | Final verification | ✅ / ❌ |

### Changes Made

#### Functional
- List each user-visible or behavior change.

#### Non-Functional
- List documentation updates, refactors, test additions, build changes, etc.

### Code Smells and Engineering Issues Noticed

- List any technical debt, fragile patterns, duplication, or potential bugs
  observed while working. Include file paths or function names when relevant.

### Remaining Dangling Artifacts

- List any branches, stashes, worktrees, or untracked files left behind that
  the user may want to review. If none, write "None."
```

## What Not to Do

- Do not delete unmerged branches or stashes without user confirmation.
- Do not commit directly to `main` unless explicitly instructed.
- Do not add platform-specific frameworks to the core `MediaMetadata` target.
- Do not treat framework-detected format as truth.
- Do not collapse timestamp evidence into a single "best" value. The public
  contract exposes every date as its own typed field; resolving which one is
  authoritative is the consumer's job, not the library's.
- Do not run `git push --force` or rewrite shared history.
