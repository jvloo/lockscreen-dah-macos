# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.1.2] - 2026-07-25

### Fixed

- Closed a gap where an unrecognized face could keep the screen unlocked
  indefinitely. Matching used two separate thresholds — one to confirm the
  owner, a much lower one to confirm a stranger — leaving a dead zone in
  between where a face was neither, and the presence chain's seat-continuity
  fallback (any face keeps it alive) held the screen open for it forever.
- A fixed 2 s "recent keyboard/mouse input counts as presence" window could
  silently override a faster "Start Countdown After" setting — covering the
  camera right after typing took ~3 s to alert instead of the configured 1 s.
  Rather than re-tune that window, it's removed: the presence chain now
  relies solely on face/body detection, so any grace-period setting behaves
  exactly as configured.
- A face already flagged as a confirmed stranger this frame could still
  refresh the seat-continuity timer, because the "keep the chain alive"
  check only asked "is there a face" and not "whose". In practice: someone
  taking over your seat right after you leave got up to 2 free frames of
  presence-timer refresh from their own (already-flagged) face before the
  stranger streak could break the chain — roughly doubling the real time to
  countdown versus an empty seat. A face already flagged a stranger this
  frame no longer counts toward continuity.
- The camera capture session could fail to start once (a transient hiccup —
  camera briefly busy, device still enumerating right after sleep/wake) and
  then silently never try again for the rest of the app's life: a one-time
  "configuration failed" flag was permanently sticky, so nothing ever
  re-attempted it. Meanwhile the state machine set `.watching` (and the menu
  showed "Watching for you") regardless of whether the camera actually came
  up. Concretely: monitoring auto-resumed at a schedule boundary while the
  Mac was asleep or the camera briefly unavailable, and stayed in this
  phantom "on but blind" state indefinitely afterward. Now: configuration
  retries on every start attempt, and a few seconds after starting, the app
  confirms the capture session is actually running — if not, it falls back
  to Paused and alerts you, instead of reporting protection it isn't
  providing.
- "Open at Login" could end up double-registered in System Settings after
  reinstalling the app. Each rebuild produces a new ad-hoc code signature,
  and macOS's login-item registration doesn't reliably carry over across
  that, so the app's own "did we already do this" flag (set once, on the
  very first run ever, and never revisited) had no way to notice the OS-side
  registration for the new build was missing — clicking "Open at Login"
  again then added a second entry alongside the orphaned one from the
  previous build instead of replacing it. Registration is now reconciled
  against a persisted user-intent preference on every launch (not just the
  first), and both the launch-time sync and the manual toggle clear out any
  stale registration before adding a fresh one. Existing duplicate entries
  from before this fix need a one-time manual removal in System Settings →
  General → Login Items.

## [1.1.1] - 2026-07-22

### Added

- README overhaul: a Features summary and table of contents up top, the
  previously separate Security model / Potential risks / Security audit /
  Caveats sections consolidated into one Security section (Model / Risks /
  Audit findings), and branding — a face-scan icon and an illustrative
  `docs/demo.gif` of the menu bar → countdown → lock sequence.
- About panel now shows the custom face-scan-and-lock icon
  (`Resources/Icon.png`, template-rendered so it still adapts to light/dark)
  instead of the generic system FaceID glyph.

## [1.1.0] - 2026-07-22

### Fixed

- Camera permission is now checked on every path that starts monitoring,
  including resume-from-lock, not just the manual toggle. Closes a corner
  case where a permission revoked while the Mac was locked could leave
  monitoring silently unable to see anything until the next lock cycle.

### Changed

- About panel's update check is now two-step: "Check for Update" records the
  result (persisted across launches) and only switches to "Download Update"
  once a newer release is actually found. Status line reads "You're up to
  date" or "New version available", each with the last-check time.
- Tightened copy across the app and README (fewer em dashes).

## [1.0.0] - 2026-07-21

### Added

- On-device presence monitoring: Vision face detection plus a Core ML
  MobileFaceNet identity embedding (InsightFace `w600k_mbf`, landmark-aligned),
  matched by cosine similarity against an enrolled profile.
- Seat-continuity presence chain — a face at any angle, an upper body in
  frame, or live keyboard/mouse input each maintain an established identity
  with no time cap.
- Camera-rest while typing: the capture session sleeps during sustained
  input and wakes as an identity gate on the next pause.
- Blackout countdown overlay before locking, cancellable only by a positive
  face match or Esc.
- KYC-style guided enrollment: three staged poses, an automatic live
  verification test, and a candidate-profile pattern — nothing overwrites
  the saved profile before Save.
- Active Hours schedule: manual Start/Pause and automatic start/end
  boundaries compose correctly across sleep, lock, and multi-day gaps via a
  timestamp-staleness check rather than polling edge-detection.
- Failsafes: repeated Esc-rescue auto-pause, post-lock verification with a
  "screen NOT protected" alert on silent lock failure, auth-gated
  re-enrollment, presence-only fallback with no profile.
- `scripts/fetch-model.sh` and `build.sh` for a from-source build with a
  pinned-checksum model download and ad-hoc Hardened Runtime codesigning.

### Security

- Hardened Runtime + camera entitlement, closing a local dylib-injection
  path into the always-camera-on process.
- Physical-HID-only input reads (`.hidSystemState`) — synthetic input can't
  fake presence.
- `profile.json` written `0600`; resume-from-lock re-verifies the real
  session-lock state instead of trusting a forgeable notification.
- `matchThreshold` clamped to `[0.2, 0.9]` at read time.

See the [Security audit](README.md#security-audit) section in the README for
the full findings list.

[Unreleased]: https://github.com/jvloo/lockscreen-dah-macos/compare/v1.1.2...HEAD
[1.1.2]: https://github.com/jvloo/lockscreen-dah-macos/releases/tag/v1.1.2
[1.1.1]: https://github.com/jvloo/lockscreen-dah-macos/releases/tag/v1.1.1
[1.1.0]: https://github.com/jvloo/lockscreen-dah-macos/releases/tag/v1.1.0
[1.0.0]: https://github.com/jvloo/lockscreen-dah-macos/releases/tag/v1.0.0
