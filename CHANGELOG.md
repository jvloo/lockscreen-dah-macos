# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/).

## [1.4.3] - 2026-08-14

### Added

- **Recognition telemetry.** Every analysed frame now records what it decided:
  face and body counts, the best similarity score, the threshold it was compared
  against, whether the face was *judgeable*, and its yaw and pitch against the
  enrolled baseline.

  The app has been making an identity decision every 0.25 s and keeping no record
  of it, so every question about whether a threshold is right has been answered
  by reasoning — and the reasoning has been wrong more than once. Two things
  surfaced within minutes of switching it on: the owner scores ~0.61 in ordinary
  seated use rather than the ~0.98 measured at enrollment, and a face scoring as
  low as 0.05 can be reported as neither a match nor a stranger, because an
  unjudgeable face sets no flag and therefore sustains presence indefinitely.

  Logged at `info`, not `debug`: debug is never written to the persistent store,
  so it can only be watched live, which is useless for a symptom reported an hour
  later. `info` stays out of an ordinary `log show`, so a similarity score — not
  identifying on its own, but biometric-adjacent — is still absent from a default
  capture, while remaining readable on request:

  ```sh
  /usr/bin/log show --info --last 1h \
    --predicate 'subsystem == "com.xavierloo.lockscreen-dah" AND category == "recognition"' \
    --style compact
  ```

  No image data, no embeddings, no landmarks — angles and scores only.

### Fixed

- **The camera restarted in a loop, and twice locked the screen for no reason.**
  Three compounding faults, all measured from the app's own log and the camera
  daemon:

  1. **The staleness bar was shorter than this Mac's camera cold start.** Opening
     the device takes ~3.7 s of session configuration plus 4.03 s from the daemon
     being asked to stream to frames actually flowing — ISP power-on alone is
     1.8 s — against a 3 s bar. One teardown fired **0.66 s before the system had
     even been asked to start streaming.** Startup and mid-stream staleness now
     have separate allowances (15 s and 3 s); fusing them was the assumption that
     broke.

  2. **The liveness anchor was cleared asynchronously**, on a serial queue behind
     session configuration and frame analysis, so a new session was judged
     against the *previous* session's last-frame timestamp — already older than
     any bar. **8 of 10 teardowns reported a frame gap larger than the session
     had existed**, which is arithmetically impossible otherwise. It is now
     invalidated synchronously before the work is dispatched. Introduced by the
     supervisor added in 1.4.0.

  3. **Results from a torn-down session reset the retry ladder.** Late results
     still arrive after a teardown (measured 5.6 s), and clearing the failure
     counter meant `[30, 60, 300]` never escalated — the log shows `retry 1 in
     30s` seven times in a row, hammering a device that was already struggling.
     The hardware recorded the collision: ten `ISP_PowerOnCamera … retrying`
     errors, each adding ~1.4 s to the next start. The reset is now guarded by
     the result's own capture time.

  When a teardown landed during a countdown, the "absence was already proven"
  branch locked the screen — so this was user-visible, not merely wasteful.

  The rule now lives in `CameraLiveness`, a pure type with tests, rather than
  three lines inside a coordinator no test could construct. Each of the three
  faults was verified by reintroducing it and watching the suite fail.

## [1.4.2] - 2026-08-14

### Added

- **Unified logging.** State transitions, supervisor decisions with the
  conditions that drove them, camera lifecycle, schedule boundaries and locks.
  Every camera outage this week was diagnosed by reading source and guessing,
  because the app recorded nothing.

  Nothing derived from a face is logged — no embeddings, no landmarks, no
  images. Read it with:

  ```sh
  /usr/bin/log show --last 1h \
    --predicate 'subsystem == "com.xavierloo.lockscreen-dah"' --style compact
  ```

  (`log` is also a zsh builtin, so the full path matters.)

### Fixed

- **Every start blacked out a seated user for over a second.** The grace
  deadline waited for the camera's first frame, but a frame nobody has analysed
  is as blind as no frame: the first Core ML inference carries model load and
  ANE warm-up, measured at **2.39 s** after start against a first frame at
  ~150 ms. A 1 s grace expired entirely inside that window, so recognition was
  never given the chance to answer before the countdown began.

  This is the intermittent "countdown flickering" reported earlier and wrongly
  attributed to the ambiguity band — that was a real bug too, but not this one.
  Found by the logging above, in its first minute of running.

  The deadline now anchors to the first analysis *result*, bounded by an
  allowance so a pipeline that delivers frames but never results still fails
  closed rather than never locking.

### Internal

- The coordinator's lock, resume and camera-liveness decisions moved into
  `PresenceSupervisor`, a pure type with tests. The three bugs shipped this week
  all lived in 950 lines of AppKit that no test could construct; each is now a
  one-line assertion, verified by reintroducing the bug and watching the suite
  fail. Lock and sleep notifications now only prompt an immediate re-decision
  rather than carrying their own logic, so they cannot drift from the poll.

## [1.4.1] - 2026-08-14

### Fixed

- **The camera restarted behind a sleeping display.** A regression in 1.4.0.
  `.locked` is entered for two unrelated reasons — the session locked, or the
  display slept without locking — and the new supervisor read the second as a
  missed unlock notification. On any Mac that doesn't lock immediately on
  display sleep, the camera stopped and then came back a second later and ran
  indefinitely behind a black screen. The supervisor now reads
  `CGDisplayIsAsleep` directly, rather than tracking a flag that would only be
  as reliable as the notification setting it.

- **A countdown was abandoned if the display slept before it finished.** The
  sleep handler parked the app in `.locked` without ever locking, so a machine
  whose owner had already been proven absent was left unlocked behind a dark
  screen — protected only by whatever "require password after sleep" setting
  the user happens to have, which this app neither sets nor reads. Absence
  proven before the display slept is real evidence, so it now locks, using the
  same rule the blind-camera path already used.

## [1.4.0] - 2026-08-13

### Added

- **A fourth enrollment pose: looking down at the keyboard.** The posture asked
  about most, and the one the profile had no template for — which is what let
  the owner's own face score as unrecognised while typing.
- **Pose diagnostics.** Enrollment appends the head angles it measures, and
  whether each was accepted, to `~/Library/Logs/LockscreenDah/enrollment-poses.log`
  (angles only — no image data). Every enrollment bug so far has been a wrong
  number in a pose gate, diagnosed by guessing at what Vision reports instead of
  reading it. Appends rather than truncates: it originally reset on `begin()`,
  and Re-Enroll calls `begin()`, so retrying a failed enrollment erased the
  record of the failure.
- `EnrollmentStages`, a pure type holding the pose gates, with tests. The gates
  had no coverage precisely because they lived inside a controller that needs a
  camera.

### Removed

- **"Idle when typing" is gone.** It stopped the capture session during
  sustained typing and let keystrokes stand in for a verified face — and an
  intruder's own typing was what *kept* the camera asleep, so the blind window
  was unbounded and attacker-controlled. That is the one thing this app exists
  to prevent, so it is removed rather than defaulted off: a setting that
  silently disables the core guarantee shouldn't be one click away.

  Measured before deciding: the capture pipeline alone costs ~5.5% of one core
  (Vision and Core ML add ~3% on top), so the feature did save something real —
  not the negligible amount first assumed. It was removed knowing that price.

  Gone with it: `cameraRestAfter`, `cameraWakeQuiet` and their menu rows, the
  rest/wake/peek machinery, `cameraMinAwake`, `cameraRestMinimumGrace`,
  `CameraRestPolicy`, the "Idle while typing" status and 💤 icon, and two
  watch-list entries. Stored values for the removed settings are simply ignored.

### Fixed

- **The countdown overlay could flash on and off while you were sitting there.**
  Removing camera idling exposed it: sustained typing used to put the camera to
  sleep and let keystrokes carry presence, so recognition was never consulted and
  a marginal profile could never produce a blackout. With the camera watching
  continuously it is consulted every second, including while you look down at the
  keyboard.

  The underlying fault was that a continuous similarity score was collapsed into
  two booleans at a single threshold, so a face scoring just under the match bar
  was reported identically to one scoring near zero — and a single such frame
  withheld seat continuity. Four in a row put a blackout on screen. An ambiguous
  band between "confidently you" and "confidently not you" is restored, and
  ambiguity now sustains presence exactly as a turned head does.

  That band was removed in v1.1.2 for a real reason — a stranger scoring inside
  it could hold the screen open indefinitely — but the fault was in the
  *continuity* rule, which counted any face regardless of identity. Continuity
  now ignores a flagged face, so the fault is fixed at its source; collapsing the
  band only ever cost the owner false countdowns.

- **An ambiguous face can no longer hold the screen open indefinitely.**
  Restoring the ambiguous band left a gap: a stranger scoring between the two
  thresholds sustained presence forever, because seat continuity has no time
  cap — by design, so that working turned toward a second screen never nags.

  Closed by separating "the model couldn't see well enough to judge" from "the
  model looked and wasn't sure". A face is now judged only when near-frontal on
  **both** yaw and pitch; yaw alone treated a head tipped down at the keyboard as
  frontal, judged it, and accused the owner. A judgeable face that fails to
  confirm starts a 5 s clock, after which it stops sustaining presence.
  Turned-away faces and torsos are never put on that clock, so the second-screen
  case is untouched. Confidence sets the speed: certain mismatch ends the chain
  in three frames, uncertainty gets five seconds to resolve.

### Changed

- **Match threshold raised from 0.35 to 0.45.** With turned and head-down poses
  enrolled, a held-out live frame scores ~0.96 against the profile, so the old
  bar sat far below anything the owner produces and gave that much more room to
  a look-alike. Raising it moves a partial match from "accepted outright" into
  the bounded ambiguous band. Not raised further: head-down is both the weakest
  scoring pose and the one held longest while typing, so it sets the real floor.

- **Enrollment's self-check is scored leave-one-out.** Each sample was measured
  against a profile built from those same samples — the template partly *is* the
  sample — so the reported score flattered itself. Since that number is what a
  decision to tighten the threshold rests on, the bias read as headroom that did
  not exist. Each sample is now scored against templates rebuilt from the other
  fifteen.

- **Camera liveness is now supervised continuously instead of checked once.**
  The old design verified the session 3 s after start and then assumed it healthy
  forever — the "has delivered a frame" flag was sticky, so a session that died
  later was invisible. `FaceMonitor` now records the instant of every frame and
  the 1 Hz tick asserts the gap stays under 3 s. Frames arrive at the sensor's
  rate regardless of the analysis throttle, so a gap is unambiguous, and one rule
  covers both "never came up" and "died later". `verifyCameraStarted`,
  `hasDeliveredFrame` and `framesSinceStart` are gone with it.
- **Camera retries no longer give up.** The previous ladder stopped after three
  attempts (~6.5 min) and paused permanently, so a camera held longer than that
  by another app cost protection for the rest of the day. Backoff now holds at
  5 minutes and repeats indefinitely; the user is told once, and the struck-through
  icon and status line carry it after that.
- **A dead camera no longer locks you repeatedly.** On a stale camera the app now
  asks whether absence was *already proven* before it went blind. If the grace
  period had elapsed while it could still see, that is real evidence and it locks
  — once. Otherwise it holds the screen and retries. Locking because our own
  camera broke punishes the user for our fault.
- **"Start Countdown After" now defaults to 1 s** (was 3 s). A security tool
  shouldn't ship a weaker default than the one it recommends, and the cost is
  CPU rather than reliability: the analysis cadence scales with the setting
  (`delay/4`), so roughly four detection attempts fit inside the window at any
  value. Measured difference is about 2% of one core. Existing installs keep
  whatever they have set.

### Fixed

- The sensor frame-rate cap never worked, and the docs stated its result as
  fact. The code asks for 3 fps, but every format on the test machine's built-in
  camera reports a 15 fps floor, so `min(max(3, 15), 30)` resolved to 15 — and
  the device then delivered ~27 fps regardless, including with the session preset
  removed and the format chosen by hand. The request now targets the slowest rate
  the device actually advertises, and both the code and the README say plainly
  that it is a request the hardware may ignore. The README's sampling table was
  recomputed against real delivery rather than the assumed 3 fps.
- The menu offered three rows that all said "re-enrollment" while a re-enrollment
  was owed, two of which ran the same action. The Start/Pause row is now omitted
  in that state, leaving one row that names the outcome.

- **The camera stayed off after a screen lock, indefinitely.** Locking stops
  the camera and every timer, and the only way back was the `screenIsUnlocked`
  notification. `DistributedNotificationCenter` delivery is best-effort, so a
  single missed one stranded the app with the screen unlocked, the capture
  device free, and nothing running that could ever notice. Observed in the
  field; present since v1.3.0.

  Rather than patch that path, recovery is now owned by a **supervisor that
  runs for the life of the app at a fixed cadence, independent of state**. It
  re-derives what should be true from facts it can read directly — is the
  session locked, are frames arriving — and corrects whatever disagrees. This
  is the third unrelated cause of "monitoring is on but the camera is off"
  (after a failure path that paused for the day and a retry ladder that gave
  up), and the pattern was the finding: recovery had been attached to whichever
  path happened to stop the camera, so any path nobody anticipated had none.
  Detection is centralised; the existing paths still own the remedies, so their
  backoff and lock-safety rules continue to apply.

- **Enrollment stalled at 50% of the second turn, asking the user to turn the
  other way while they already were.** The stage was handed one flat list of
  every sample collected so far — including the samples it had just accepted
  itself — to work out which direction the previous turn went. Each capture
  dragged that reference average toward zero, flipping its sign after two, at
  which point the gate rejected the exact direction it had been accepting. Gates
  now receive the samples of *completed* stages only, grouped by stage, so a
  stage cannot see its own output; the failure is no longer expressible rather
  than merely fixed.

- **The turn stages depended on a yaw sign convention that was never verified.**
  The preview is mirrored so it behaves like a mirror, while Vision measures the
  unmirrored buffer — so "left" on screen and the sign of yaw need not agree, and
  a genuine left turn was rejected by the stage asking for it. Neither turn stage
  depends on the sign now: whichever way the user turns first defines the pair,
  and the second stage requires the opposite.

- **Head tilt was judged against zero rather than the user's resting pose.** A
  laptop camera sits above the screen and reads ~0.2 rad of pitch on someone
  sitting normally, so an absolute gate measured desk geometry as much as head
  movement — and the straight-ahead stage could reject people for sitting low.
  The resting pitch captured in the first stage is now the baseline, stored in
  the profile and used by live detection too, so enrollment and detection agree
  on what level means.

## [1.3.0] - 2026-07-29

Adds Active Days, makes the countdown and lock deadlines immune to system clock
changes, and clears the last known defects from the v1.2.0 review — with test
coverage for the logic all of that touches.

### Added

- **Active Days.** The schedule now has a day-of-week filter alongside its hour
  range, defaulting to **Mon–Fri**. Set it in the same panel (menu bar →
  Settings → Active Hours…), which gains a row of weekday checkboxes and an
  "All days" toggle. At least one day must stay selected: an empty set would
  mean monitoring never runs, which reads as configured protection but provides
  none. The menu shows the current schedule ("Active Hours (9:00 AM–8:00 PM,
  Mon–Fri)…"), and the status line distinguishes "Paused (off hours)" from
  "Paused (Sat not active)", since the latter is easy to forget you configured.

  Hours and days resolve through **one** model: each active weekday opens a
  single window at the start time lasting the configured span. Overnight ranges
  fall out for free and are governed by the day they *opened* on, so a Friday
  21:00–06:00 shift stays active into Saturday morning even when Saturday isn't
  selected. Adjacent windows are merged, so a fully continuous schedule (every
  day, 24 hours) still exposes no boundary and a manual pause survives it.
- A test target (`swift test`, 76 tests) covering `PresenceTracker`, `Settings`,
  `MonitoringSchedule` and `CameraRestPolicy` — the pure types where every
  presence and timing bug in this project has actually lived. It pins down seat continuity, the stranger
  streak, the identity gates, the duration clamps, and schedule/day resolution
  including overnight ranges. Verified by reintroducing two of the fixed bugs
  and confirming the relevant tests fail. `Settings` tests run against a scratch
  defaults suite, never the real app domain.

### Changed

- The zero-countdown option is now labelled **Never Countdown** (was "Instant"),
  matching the existing "Never Idle" wording. Behaviour is unchanged: the screen
  locks the moment presence lapses, with no overlay. Since that also removes the
  Esc gesture, a lock-loop fallback covers it (below).
- Every stored setting is now range-checked on read, and the schedule panel
  refuses invalid combinations instead of reinterpreting them. Equal start and
  end times are rejected (they had no honest reading — a whole day, or none of
  it?), as is an empty day selection. Start/end minutes are clamped to a real
  time of day, because an out-of-range value reached `date(bySettingHour:)` as
  e.g. hour 83, which returns nil and would have silently dropped the day's
  window and left monitoring never starting. "Idle When Typing For" and "Wake
  From Idle After" are clamped too. The 24-hour schedule is now expressed by
  "Always on" alone.
- **Esc no longer cancels a countdown on its own.** A single un-checked keypress
  that dismisses a lock was the bypass an intruder would reach for, so it now
  takes three presses on the *same* overlay, which then asks the Mac to verify
  who is pressing. The gesture is only revealed after the first press, so a
  passerby still sees a blank screen. The lock is held while the prompt is up;
  dismissing or failing it restores the countdown exactly where it was, so an
  intruder gains nothing and the screen still locks.
- Camera idling's blind window is **left unbounded, deliberately**, and that is
  now written down rather than implied. While resting the camera is stopped and
  presence rests on keystrokes alone — and unlike the body-detection gap it isn't
  bounded in practice either, because an intruder holding a key keeps input
  flowing, which is exactly what keeps the camera asleep. A 10 s ceiling with a
  2 s "peek" was built and measured, but enforcing it reopens the camera every
  10 s forever (~10–18% duty cycle against ~0%, re-running auto-exposure each
  time), which wasn't judged worth paying continuously. The machinery remains in
  the code behind `cameraRestMaxDuration`. **The supported answer to this threat
  is "Never Idle"**, which removes the window entirely at a steady CPU cost. See
  [docs/TESTING.md](docs/TESTING.md) entry 2 for the attack and the tradeoff.
- **"Never Countdown" can no longer trap you in a lock loop.** With no overlay
  there is no Esc gesture, and a recognizer that has stopped matching you would
  lock the screen again seconds after every login with no in-app way out. Locks
  with no successful match in between are now counted — persisted, since each
  iteration passes through a screen lock — and after two of them a minimum 3 s
  countdown is restored so the escape gesture exists again. Any real match clears
  it and instant locking resumes.
- The lock during that verification is **deferred, never cancelled** (bounded at
  15 s). An earlier cut of this stopped every timer that could fire the lock and
  relied on the prompt's completion handler to restart them, so a prompt nobody
  answered parked the app in `.alerting` indefinitely with the overlay up and the
  machine unlocked behind what reads as a sleeping display. Silence is not
  authorisation: when the grace expires the prompt is invalidated and the screen
  locks. Verification attempts are also capped per overlay — without that, every
  press after the third re-prompted, so an intruder could keep deferring.
- Passing that verification pauses monitoring, which then **will not resume
  automatically** — not on a schedule boundary, an unlock, or a display wake —
  until you re-enroll. The requirement is persisted, so quitting can't clear it,
  and your existing profile keeps working until the new one is saved.
- Broke the fat controller apart. `AppDelegate` went from 456 lines to 15 — menu
  construction, the custom menu row and login-item reconciliation now live in
  `StatusMenuController`, `StayOpenOptionView` and `LoginItem`. Schedule
  resolution left `Settings` for `MonitoringSchedule`, which takes its calendar as
  a parameter, so DST transitions, time zones and first-day-of-week behaviour are
  testable for the first time rather than being asserted against whatever machine
  happened to run the suite. The camera rest/wake decision became
  `CameraRestPolicy`, a pure function — its edges are security edges, since they
  decide when the app is deliberately blind, and were previously reachable only by
  typing at a laptop and watching. Both deadline timers share one `DeadlineTimer`,
  so the monotonic conversion the whole clock fix rests on exists once.
  `MonitorCoordinator` is still large; the decision-layer extraction is next.
- Added [docs/TESTING.md](docs/TESTING.md): a manual checklist for everything
  tests can't reach, plus a watch list of deliberately-accepted risks with what
  to look for in each.
- The countdown and lock deadlines are now measured on a **monotonic clock**
  instead of wall-clock time. A forward system clock step (a manual date change,
  or `timed` stepping rather than slewing an NTP correction) used to fire both
  that much early, and both defensive re-checks were written against the same
  shifted clock so neither could catch it. Active Hours deliberately still
  follows wall-clock time: if the system date changes, the schedule should move
  with it.

### Fixed


- **A camera that failed to start disabled protection for the rest of the day.**
  The failure path called `pause()`, which stamps the "last decision" timestamp —
  the mechanism that deliberately makes a *user's* pause survive sleep and lock
  until the next schedule boundary. Applied to a hardware stumble that meant a
  one-second hiccup left the screen unwatched for hours, with only a dismissible
  modal as evidence. Found while troubleshooting a real occurrence.

  A failure now enters a new `cameraUnavailable` state and retries after 30 s,
  60 s and 300 s without consuming a schedule decision; any delivered frame
  resets the count, and only after all three retries does it become a real
  paused-with-alert. The state is deliberately its own case rather than a flag:
  it must not read as `watching` (claiming protection it isn't providing) nor as
  `paused` (which means the user chose it). The menu-bar icon shows a
  struck-through camera and the status line reads "Camera unavailable —
  retrying".

- **Ticking "Always on" left monitoring off while the UI said it was on.** The
  schedule panel writes `scheduleEnabled` before notifying the coordinator, and
  the coordinator's handler guarded on that same flag — so the one change that
  expands coverage to 24/7 guarded itself out. The periodic resolver carried the
  same guard, so nothing recovered it short of a relaunch, which is why it
  survived testing. From a paused state the app now starts as instructed.
- `consecutiveLocksWithoutMatch` was the one security control read without a
  range check. A stored negative made the threshold test unreachable and silently
  removed the only failsafe against a "Never Countdown" lock loop. Now clamped and
  saturated, like every other control.
- `countdownDuration` shared the generic 0.5 s duration floor, so
  `defaults write` could produce a countdown shorter than the Esc gesture that is
  explicitly sized against it ("three presses plus a Touch ID round trip"). It now
  has its own floor of 3 s — the shortest offered value. `gracePeriod` keeps the
  lower shared floor on purpose, so camera idling can still be ruled unavailable.
- Enrollment could race the capture session. The preview layer was built from
  the same `AVCaptureSession` the monitor was still configuring on its own
  queue — concurrent mutation of one session from two threads, which
  AVFoundation doesn't support (black preview, or a thrown exception adding the
  connection). Reachable by enrolling before monitoring had ever started, e.g.
  a cold launch off hours. The preview now waits for configuration to finish.
- A capture session that hit a runtime error (camera unplugged, device seized by
  another app, wedged after a sleep/wake device re-enumeration) stayed broken for
  the rest of the app's life: the "already configured" flag latched, so no later
  start would rebuild the inputs. Configuration is now torn down on a runtime
  error and reconstructed on the next start.
- A display attached or rearranged mid-countdown was left uncovered, mirroring
  or extending the desktop the blackout exists to hide. The overlay now rebuilds
  for the new screen layout — without replaying the chime or restarting the
  fade, so plugging in a monitor doesn't look like a fresh countdown.

### Upgrading

- Monitoring now pauses at weekends by default. Pick **All days** in the Active
  Hours panel to keep the previous behaviour.
- A stored duration no longer offered in the menus (a 30 s delay, a 1 s
  countdown) stays in effect until you pick a new one — settings are not
  rewritten behind your back.

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

[Unreleased]: https://github.com/jvloo/lockscreen-dah-macos/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/jvloo/lockscreen-dah-macos/releases/tag/v1.3.0
[1.2.0]: https://github.com/jvloo/lockscreen-dah-macos/releases/tag/v1.2.0
[1.1.2]: https://github.com/jvloo/lockscreen-dah-macos/releases/tag/v1.1.2
[1.1.1]: https://github.com/jvloo/lockscreen-dah-macos/releases/tag/v1.1.1
[1.1.0]: https://github.com/jvloo/lockscreen-dah-macos/releases/tag/v1.1.0
[1.0.0]: https://github.com/jvloo/lockscreen-dah-macos/releases/tag/v1.0.0
