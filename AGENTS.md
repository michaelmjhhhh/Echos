# Dev Rules

## Tone

- Keep answers short and concise
- No emojis in commits, issues, PR comments, or code
- No fluff or cheerful filler text. 
- Technical prose only, be direct
- Use concise, clear, simple language. Define unavoidable jargon before using it.
Explain non-trivial designs and problems as: problem, concrete example or short trace, then solution. State why the solution is necessary and distinguish it from optional complexity.
- Prefer concrete behavior and small illustrations over abstract summaries, dense terminology, or unexplained lists of changes.
- When the user asks a question, answer it first before making edits or running implementation commands.
- When responding to user feedback or an analysis, explicitly say whether you agree or disagree before saying what you changed.

## Tests

Do not NEVER EVER write any unit tests. 

## Git

For non-trivial changes, always work on a separate git branch.
Always use conventional commit.
For non-trivial changes, ask the user whether we should open an issue or not. 

Your issue/PR description should be concise and simple. keep it short, concrete, and worth reading. 

## Changelog

- Every user-facing or engineering update must update `CHANGELOG.md` in the same PR, including fixes, build changes, dependency changes, and documentation changes.
- Put unreleased changes under `## [Unreleased]`. Use `### Added`, `### Changed`, `### Fixed`, or `### Removed` only when needed. Describe concrete behavior and its effect; do not copy commit subjects or claim unmeasured improvements.
- Before releasing, move the relevant entries into `## [X.Y.Z] - YYYY-MM-DD`. Keep newest versions first and preserve older entries. Record material limitations alongside the changes.

## Releases

- Use semantic versions, a `vX.Y.Z` tag, and the GitHub release title `Echo vX.Y.Z`. The tag, `project.yml` app version, built app version, and changelog version must agree. Increment the app build number for each release.
- Merge the reviewed PR to `main` after required checks pass, then tag the merged commit. Push the tag to run `.github/workflows/release.yml`; it validates again before publishing. Manual workflow runs build artifacts without publishing.
- Generate release notes from the matching changelog entry. Use this order: `## Changes` (including material limitations), `## Install`, `## Verification`, then a `Full Changelog` compare link. Do not substitute automatically generated commit lists for the changelog.
- Installation notes must state supported hardware/macOS, permissions, model setup, and the actual signing/notarization status. Include quarantine instructions only for the ad-hoc build. Never describe ad-hoc signing as Developer ID signing or notarization.
- Attach `Echo-vX.Y.Z.dmg`, `SHA256SUMS`, and `Echo-vX.Y.Z-build.json`. Verification notes must link the successful workflow and record the source commit and dependency-lock hash in the build manifest. Distinguish synthetic replay, automated checks, and real device testing; do not claim general accuracy or latency improvements from synthetic samples.

## User Override

If the user's instructions conflict with any rule in this document, ask for explicit confirmation before overriding. Only then execute their instructions.
