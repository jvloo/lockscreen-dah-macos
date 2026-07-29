# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.2.1] - 2026-07-29

Clears the remaining known defects from the v1.2.0 review, and adds the test
coverage that would have caught most of what that review found by hand.

### Added

- A test target (`swift test`, 32 tests) covering `PresenceTracker` and
  `Settings` — the two pure value types where every presence and timing bug in
  this project has actually lived. It pins down seat continuity, the stranger
  streak, the identity gates, the duration clamps, Active Hours boundary
  resolution including overnight ranges, and the "a confirmed stranger's own
  face must not refresh the presence clock" rule. Verified by reintroducing two
  of the fixed bugs and confirming the relevant tests fail. `Settings` tests run
  against a scratch defaults suite, never the real app domain.

### Fixed

- Enrollment could race the capture session. The preview layer was built from
  the same `AVCaptureSession` the monitor was still configuring on its own
  queue — concurrent mutation of one session from two threads, which
  AVFoundation doesn't support (black preview, or a thrown exception adding the
  connection). Reachable by enrolling before monitoring had ever started, e.g.
  from a cold launch off hours. The preview now waits for configuration to
  finish.
- A capture session that hit a runtime error (camera unplugged, device seized by
  another app, wedged after a sleep/wake device re-enumeration) stayed broken for
  the rest of the app's life: the "already configured" flag latched, so no later
  start would rebuild the inputs. The session's configuration is now torn down on
  a runtime error, so the next start reconstructs it against whatever device is
  present.
- A display attached or rearranged mid-countdown was left uncovered, mirroring
  or extending the desktop the blackout exists to hide. The overlay now rebuilds
  for the new screen layout — without replaying the chime or restarting the
  fade, so plugging in a monitor doesn't look like a fresh countdown.

## [1.2.0] - 2026-07-29

A timing-accuracy release. Both deadlines the app promises (when the countdown
appears, when the screen locks) were decided by polling timers and drifted late,
and reviewing that turned up several ways the countdown could fire when it
shouldn't. That review also showed some of the offered duration settings could
not do what their labels implied, so the four duration menus were reworked and a
new Instant option added. Timings below were measured, not estimated.

### Fixed

- The countdown now appears at the configured "Start Countdown After" instead
  of up to 1.02 s late (0.51 s on average). It was decided by a 1 Hz poll whose
  phase was anchored to when monitoring started rather than to when presence
  was lost. Both deadlines are now precise one-shot timers, measured accurate
  to 3-5 ms.
- The screen now locks at the configured "Countdown Duration" instead of up to
  0.27 s late, same cause (a 0.25 s poll). That tick now only redraws the
  overlay.
- The countdown duration is measured from when the overlay is actually on
  screen. It used to start before the overlay windows were built and the app
  activated, and the fade-in took another 0.5 s on top, so the warning you
  could actually read was about half a second shorter than configured. At the
  1 s setting that was half of it. The fade is now 0.2 s.
- Presence is timestamped at frame capture rather than after analysis. Vision
  plus up to four Core ML embeddings plus a hop to the main thread is
  100-400 ms, and all of it used to count against you as absence.
- The grace period no longer counts time when the camera was not yet looking.
  It was anchored to the moment monitoring started, but opening a capture
  session takes about a second to produce a first frame, which a short grace
  period expires entirely inside. At the 1 s setting that meant a full-screen
  blackout roughly 1.4 s after every unlock, with the owner sitting right
  there. It now counts from the later of "presence last confirmed" and "this
  session's first delivered frame".
- A countdown can no longer begin while the camera is resting ("Idle while
  typing"). Lowering "Start Countdown After" during a rest pulled the deadline
  in ahead of the tick that would have woken the camera, so the countdown ran
  with the capture session stopped: no face could cancel it and the lock was
  unavoidable short of Esc. Camera rest now ends and the session restarts
  instead.
- "Camera failed to start" could fire against a perfectly good camera and leave
  monitoring paused. The check was an uncancelled delayed block, so Start,
  Pause, Start within its window left the stale check judging the new session.
  It is now bound to the session it was scheduled for.
- Camera health is judged by whether the session has actually delivered a
  frame, not by whether it claims to be running, and that is reset when the
  session stops. A stopped or wedged camera can no longer read as healthy.
- Denying camera access during enrollment left the capture session running
  behind a menu reading "Paused", with no way back. It now tears down properly.
- The Esc failsafe no longer counts an Esc that cancelled nothing, and clears
  its strikes after a re-enrollment, so it can't pause monitoring to repeat
  advice you just followed.
- "Start Countdown After" and "Countdown Duration" are clamped when read. Now
  that both are precise one-shot timers, a stray or tampered value of zero or
  less would schedule a fire date in the past and spin the run loop.

### Changed

- Reworked the four duration settings so every option does what its label says
  and none silently disables another:

  | Setting | Was | Now |
  |---|---|---|
  | Start Countdown After | 1/3/5/10/15/30 s | **1/3/5/10 s** |
  | Countdown Duration | 1/3/5/10/15/30 s | **3/5/10 s or Instant** |
  | Idle When Typing For | 5/10/15/30 s / Never | **10/20/30 s / Never** |
  | Wake From Idle After | 1/2/3/5/10 s | **1/2/3/5 s** |

  Countdown 1 s is gone because cancelling one takes about a second in practice,
  so it was a lock with no real appeal rather than a warning; the two duration
  pickers no longer share a single list, since detection delay and countdown
  length have different floors. 15 and 30 s detection delays are gone because
  sampling caps at 2.5 s above 10 s, making them identical in cost and differing
  only in how long you stay exposed. Idle 5 s is gone because the 20 s minimum
  awake time made it behave the same as 10 s. Wake 10 s is gone because it left
  a stranger invisible for up to ten seconds of continuous typing.
- New **Instant** countdown option: locks the moment presence lapses, with no
  overlay. Note it has no escape hatch — no overlay means no Esc, so the
  Esc-rescue failsafe can't intervene if recognition starts misjudging you.
- Detection sampling is meaningfully more accurate at short delays. The
  "confirming absence" cadence was 0.4 s, which rounded up to two frame periods
  against the 3 fps sensor cap and silently discarded every other frame already
  paid for; it is now below one frame period, so every frame is analyzed. The
  idle cadence scales as `delay/4` rather than `delay/3`. At the 1 s setting the
  countdown's worst-case earliness halves (1.0 s → 0.33 s) and roughly twice as
  many detection attempts fit inside the window, so a single bad frame no longer
  causes a blackout.
- Camera idling is unavailable below a 3 s countdown delay (unchanged), but the
  menu now greys those two rows out and shows the reason instead of accepting
  the setting and ignoring it.
- Camera-rest wake-up is a single shared path, and the restarted session gets
  the same startup verification as any other.

### Known limits

- Presence is sampled, not continuous, so measured from the instant you
  actually stand up the countdown appears up to one sampling interval before
  the configured time (1.0 s at the 3 s setting, 0.33 s at 1 s). It errs early,
  never late. See the README's "Start Countdown After" for the full table.
- A stored value that is no longer offered (say a 30 s delay, or a 1 s
  countdown) stays in effect until you pick a new one from the menu — settings
  are not rewritten behind your back.
- Both deadlines are wall-clock, so a forward system clock step fires them
  early. Sleep and wake are handled in the safe direction.

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

[Unreleased]: https://github.com/jvloo/lockscreen-dah-macos/compare/v1.2.1...HEAD
[1.2.1]: https://github.com/jvloo/lockscreen-dah-macos/releases/tag/v1.2.1
[1.2.0]: https://github.com/jvloo/lockscreen-dah-macos/releases/tag/v1.2.0
[1.1.2]: https://github.com/jvloo/lockscreen-dah-macos/releases/tag/v1.1.2
[1.1.1]: https://github.com/jvloo/lockscreen-dah-macos/releases/tag/v1.1.1
[1.1.0]: https://github.com/jvloo/lockscreen-dah-macos/releases/tag/v1.1.0
[1.0.0]: https://github.com/jvloo/lockscreen-dah-macos/releases/tag/v1.0.0
