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
  Fixtures/            # Real-media golden corpus (see its README.md)
Scripts/               # Fixture tooling; cloud-setup.sh (cloud SessionStart hook)
.github/workflows/     # ci.yml (macOS + Linux + guardrail), release.yml
.github/release-notes/ # Optional X.Y.Z.md release notes, read by release.yml
.claude/settings.json  # Claude Code project settings (SessionStart hook)
Package.swift          # SPM manifest
README.md              # Consumer-facing documentation
ARCHITECTURE.md        # Design contract, non-goals, guardrails
LICENSE                # MIT
```

## Build, Test, and Verify

```sh
swift build
swift test
```

CI (`.github/workflows/ci.yml`) runs on every pull request and every push to
`main`:

- **macOS** (`macos-15`): `swift build`, `swift test`, and
  `xcodebuild -scheme MediaMetadata -destination 'platform=macOS' test`.
- **Linux** (`swift:6.0` container): `swift build`, `swift test`.
- **Guardrail**: the core target imports no platform framework.

macOS coverage comes from CI; no step of this process uses a personal machine.

## Cloud Sessions

The whole process runs from a Claude Code cloud session (claude.ai/code): an
Ubuntu 24.04 x86_64 VM with no macOS and no preinstalled Swift.

- The SessionStart hook in `.claude/settings.json` runs
  `Scripts/cloud-setup.sh`, which installs the Swift release CI's Linux job
  uses (6.0.3, signature-checked from swift.org) into `/opt/swift-<version>`
  and puts it on `PATH`. It acts only when `CLAUDE_CODE_REMOTE=true`, and a
  second run is a fast no-op. When CI's `swift:` image moves, update the
  default version in the script.
- `swift build` and `swift test` run in the VM. The golden test skips the three
  large public fixtures unless `Scripts/check-local-fixtures.sh` fetched them
  (see Owner setup for the hosts a limited network must allow).
- The GitHub proxy allows git fetch and push of branches, REST calls on this
  repository, and `repository_dispatch` to it. It refuses tag pushes, remote
  branch deletion, REST ref and release writes, GraphQL (so every `gh pr …`
  and `gh release …` command fails; use `gh api` REST), repository settings,
  Actions secrets, and other repositories. Work the proxy refuses runs in an
  Actions workflow with `GITHUB_TOKEN`, third-party actions pinned by full
  commit SHA.
- This repository is public: workflow logs must never print secrets or
  personal data.

Set these once per shell to keep the commands below short:

```sh
repo=repos/tonimelisma/MediaMetadata
branch="$(git branch --show-current)"
```

Toni's standing rules (they live in his personal `~/.claude/CLAUDE.md`, which
does not reach cloud sessions, so they are repeated here):

- When it is already clear what Toni wants, do it. Never ask whether or how to
  do it, or which piece to do first, and never end a turn with a go-ahead
  question. Ask only for what only Toni can do (his accounts, devices,
  approvals) or a real product choice he hasn't made yet.
- Never end a turn while any item Toni asked for can still move forward
  without him. When one item is blocked, go on to the next; stop only when
  every item is done or truly blocked, and list just the Toni-only steps at
  the end.
- Live tests may write to Toni's real apps; every test removes what it made in
  its own teardown, even when it fails, and confirms the removal. Never leave
  test data behind.

## Releases

`.github/workflows/release.yml` tags and releases with `GITHUB_TOKEN`, because a
cloud session cannot push tags or write releases.

- **A merged version bump is the release.** Bump the README install pin
  (`.package(url: "https://github.com/tonimelisma/MediaMetadata.git", from: "X.Y.Z")`)
  in the pull request, and add `.github/release-notes/X.Y.Z.md` with the
  user-visible changes (without it, GitHub's generated notes are used). Once
  CI passes on the merge commit on `main`, the workflow tags that commit
  `X.Y.Z` (no `v` prefix, matching existing tags) and creates the release.
- Version choice: pre-1.0, a breaking public-API change bumps the minor
  (`0.9.5` → `0.10.0`); a backward-compatible change bumps the patch. Release
  only when `main` has user-visible changes since the latest tag.
- The workflow refuses a pin below the latest tag. It is idempotent: a pin
  equal to the latest tag finishes a missing release on the existing tag, or
  does nothing.
- Retry (same checks; the version must equal `main`'s pin and CI must have
  passed on `main`'s head):

  ```sh
  gh api "$repo/dispatches" -f event_type=release -f 'client_payload[version]=X.Y.Z'
  ```

- Check the run and the result:

  ```sh
  gh api "$repo/actions/workflows/release.yml/runs?per_page=3" \
    --jq '.workflow_runs[] | [.event, .status, .conclusion, .head_sha[0:7]] | @tsv'
  gh api "$repo/releases/tags/X.Y.Z" --jq '[.tag_name, .html_url] | @tsv'
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

- [ ] Work on a feature branch, never on `main`.
- [ ] Run `git status` and note all modified, staged, and untracked files.
- [ ] Run `git diff --stat` to confirm the scope of changes matches the task.
- [ ] If unrelated changes are present, stop and ask the user how to proceed.

### 2. Run the full test suite

- [ ] Run `swift build` and confirm it succeeds.
- [ ] Run `swift test` and confirm all tests pass, including
      `RealFixtureGoldenTests`.
- [ ] If any test fails, fix it before proceeding. Do not ignore failures.
- [ ] macOS (`swift test` and `xcodebuild … test`) is verified by CI in step 6.

### 3. Review changes for quality

- [ ] Inspect `git diff` for accidental edits, secrets, or debug code.
- [ ] Confirm no force unwraps were introduced unless unavoidable and documented.
- [ ] Confirm platform-specific frameworks were not added to the core target.
- [ ] Confirm new public API has DocC-style comments.
- [ ] If a workflow changed, run `actionlint` on it.

### 4. Commit

- [ ] Stage only the files intended for this increment.
- [ ] Write a concise, imperative commit message that matches repo style,
      e.g. `Add HEIF EXIF item-location parser` or `Fix RIFF list depth guard`.
- [ ] Do not commit secrets, temporary files, or unrelated changes.

### 5. Push and open a pull request

- [ ] Push the branch: `git push -u origin "$branch"`.
- [ ] If the increment has user-visible changes, bump the README pin and add
      `.github/release-notes/X.Y.Z.md` in this pull request (see Releases).
- [ ] Open the pull request over REST (`gh pr create` needs GraphQL):

  ```sh
  gh api "$repo/pulls" -f title="…" -f head="$branch" -f base=main \
    -f body="$(cat pr-body.md)" --jq '[.number, .html_url] | @tsv'
  ```

### 6. Wait for green CI, then merge

- [ ] Poll the check runs on the pull request's head commit until every run
      has completed and succeeded (macOS, Linux, guardrail):

  ```sh
  sha="$(git rev-parse HEAD)"
  gh api "$repo/commits/$sha/check-runs" \
    --jq '.check_runs[] | [.name, .status, .conclusion] | @tsv'
  ```

- [ ] If a check fails, read its log (`gh api "$repo/actions/jobs/<job id>/logs"`),
      fix, push, and wait again.
- [ ] Merge over REST, pinned to the commit CI checked:

  ```sh
  gh api -X PUT "$repo/pulls/<number>/merge" -f merge_method=merge -f sha="$sha"
  ```

- [ ] If the merge is refused (required review, failing checks), report the
      blocker and stop. Do not bypass protections.
- [ ] Verify `main` contains the merge:
      `git fetch origin main && git log origin/main --oneline -5`.

### 7. Release a new version

- [ ] If the merged pull request bumped the pin, wait for CI on `main`, then
      for the Release workflow, and confirm the tag and release exist (see
      Releases). If it failed, read its log, fix, and retry with the dispatch.
- [ ] If `main` has user-visible changes since the latest tag but no bump yet,
      open a bump pull request and take it through steps 5–7.
- [ ] With no user-visible changes since the latest tag, do not release; say so.

### 8. Preserve all work

- [ ] Before deleting any branch, worktree, or stash, confirm its commits are
      reachable from `origin/main` or another protected branch.
- [ ] Never delete unmerged work unless the user explicitly confirms it is
      disposable.
- [ ] Never drop stashes or untracked files that contain user work.

### 9. Clean up agent-created artifacts

After the merged commit is confirmed on `origin/main`:

- [ ] GitHub deletes the merged remote branch automatically; confirm it with
      `gh api "$repo/branches/$branch"` (expect 404). The proxy refuses
      deleting it from the session.
- [ ] Switch to `main` and delete the local feature branch.
- [ ] Remove any worktrees created by the agent.
- [ ] List any remaining dangling branches, stashes, or worktrees in the final
      report so the user can decide what to do with them.

### 10. Final verification

- [ ] On `main` (`git checkout main && git pull --ff-only`), run `swift build`
      and `swift test`, and confirm CI on the merge commit is green.
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
| 7 | Release a new version (or none due) | ✅ / ❌ |
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

### Owner Setup

- List every owner-only step: the Owner setup section at the end of this file,
  plus any new one.

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
  contract exposes every date as its own typed field. Opinionated selections are
  welcome where the library's format knowledge is what makes them right, but they
  must be purpose-named (`captureWallClock` for naming, `captureInstant` for
  ordering), report the role they chose, publish their precedence, and never
  replace the fields they choose from.
- Raise `MediaMetadataReader.extractionRevision(for:)` for each family whose
  already-reported values change for the same bytes, or that newly reports a field,
  and add a row to its table. A stored row cannot tell "the file has none" from "the
  parser did not look", so a new field moves it too. Do not raise it for a family the
  change does not touch.
- Do not run `git push --force` or rewrite shared history.
- Do not use a personal machine for any step; CI covers macOS.

## Owner setup

Steps only the repository owner can take. Nothing else in the process needs
the owner; this repository's workflows need no Actions secrets.

- Cloud environment network allowlist (only when the environment's network is
  limited rather than unrestricted): `terra-1-g.djicdn.com`, `api.gopro.com`
  and `media-cdn-vod-us-west-2.gopro.com`, so `Scripts/check-local-fixtures.sh`
  can fetch the three large public samples.
