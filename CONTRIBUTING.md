# Contributing to Lockscreen Dah?

Thanks for considering a contribution. This is a small, personally-maintained
macOS menu-bar app, so keep changes focused — see below for the kind of
contributions that fit best.

## Before you start

- **Bug reports and small fixes** (typos, crashes, a setting behaving oddly)
  are always welcome — open an issue or a PR directly.
- **New features or behavior changes** — open an issue first to discuss the
  approach before writing code. This app makes deliberate, sometimes
  opinionated tradeoffs around presence detection and camera privacy (see
  [Security model](README.md#security-model)); a quick discussion up front
  avoids rework.
- **Security issues** — do not open a public issue. Use GitHub's
  [private security advisory](https://github.com/jvloo/lockscreen-dah-macos/security/advisories/new)
  flow instead.

## Development setup

Requirements: macOS 13+, Xcode Command Line Tools (for `swift build` and
`codesign`), and internet access for the one-time model download.

```sh
git clone https://github.com/jvloo/lockscreen-dah-macos.git
cd lockscreen-dah-macos
scripts/fetch-model.sh   # one-time: downloads + converts the face embedding model
./build.sh --install     # builds, ad-hoc codesigns, installs to /Applications, launches
```

There's no Xcode project — this is a plain Swift Package Manager executable
target (`swift build`); `build.sh` bundles it into a `.app` and codesigns it
with Hardened Runtime. See `Package.swift` and `build.sh`.

## Testing your change

There's no automated test target — the app is almost entirely driven by
camera input and OS-level state (lock/unlock, sleep/wake, schedule
boundaries) that's impractical to unit-test in isolation. Verify changes by
running the app:

- `./build.sh --install` and exercise the affected flow end-to-end from the
  menu bar.
- For anything touching `MonitorCoordinator`'s state machine or the Active
  Hours schedule, walk through the actual state transitions rather than
  trusting a read-through — this logic is easy to get subtly wrong around
  lock/unlock and sleep, and past bugs here have only shown up in exactly
  those edge cases.
- For recognition/enrollment changes, re-enroll and confirm both a positive
  match (your face) and a negative one (someone else, or a photo) behave as
  expected.

## Code style

- Match the existing formatting and naming in the file you're editing.
- Comments explain *why*, not *what* — a hidden constraint, a tradeoff, a
  workaround for a specific OS quirk. Skip comments that just restate the
  code.
- `// MARK: -` section dividers group related functionality (see
  `MonitorCoordinator.swift` for the convention).
- Keep diffs scoped to the change at hand — this codebase deliberately
  avoids speculative abstraction and unused configurability.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org/) with a scope,
e.g. `fix(schedule): ...`, `feat(enrollment): ...` — focus the message on
*why*, not a restatement of the diff.

## Pull requests

- Keep each PR focused on one change; unrelated cleanup makes review harder.
- Describe what you tested manually (see
  [Testing your change](#testing-your-change)) — with no CI test suite, this
  is the reviewer's main signal.

## License

By contributing, you agree your contribution is licensed under the
project's [MIT License](LICENSE).
