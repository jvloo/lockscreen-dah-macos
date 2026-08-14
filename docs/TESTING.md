# Testing & watch list

`swift test` covers `PresenceTracker`, `Settings`, `MonitoringSchedule` and
`EnrollmentStages` — the pure logic where every presence, timing and enrollment
bug in this project has actually lived. Everything below is
what a test **can't** reach: it needs a real camera, a real face, and in a couple
of cases a second person.

## Watch list

Known-risk behaviours that are deliberately allowed rather than fixed. Each one
says what to look for, so a report is "I saw X" rather than "it feels off".

### 0. The match threshold is set from a single enrollment session

**Status:** on watch. **Added:** when the threshold went 0.35 → 0.45.

0.45 is set against measured scores — a held-out live frame at ~0.96, the
weakest enrolled pose at ~0.71 — but every one of those numbers was captured
within minutes of enrolling: one lighting condition, one distance, one day. The
threshold has never been checked against the variation of ordinary use.

The binding pose is head-down-while-typing: it scores lowest *and* is held
longest, and it is judgeable, so a sustained under-threshold score there breaks
the presence chain after 5 s and starts a countdown.

**What to look for:** a countdown while you are sitting there typing with your
head down. That is the signature of the threshold being too tight, and the fix
is `matchThreshold` back to 0.35 — not another pose gate. Tightening further
(0.55) needs the owner's live score distribution across a real day, which
nothing currently records.

### 1. Pitch tolerance is an informed guess, not a tuned value

**Status:** on watch. **Added:** with the judgeable-face change.

A face is only judged — matched against or accused — when it is near-frontal on
**both** yaw and pitch (0.5 rad, ~30°). Yaw alone treated a head tipped down at
the keyboard as frontal, judged it, and accused the owner's own face.

The pitch limit was reasoned about, not measured against real seating. Too tight
and a stranger looking slightly down is never judged; too loose and the original
false-accusation returns.

**What to look for:** blackouts while you read the keyboard (too loose), or a
colleague sitting frontally who never triggers a countdown (too tight). Both
point at `maxStrangerPitch` in `FaceMonitor.swift`.

### 2. Stranger who never faces the camera

**Status:** accepted. Rationale below.

Body detection (`VNDetectHumanRectanglesRequest`) answers "is a person there",
never "which person" — a torso carries no identity signal, and it only runs on
frames with no face at all. So a torso in frame maintains the chain with no time
cap, and the stranger challenge can't help because it only judges near-frontal
faces.

**Why this is accepted rather than capped:** an intruder has to *look at the
screen* to do anything with the machine. The moment they do, the face becomes
judgeable and one of two things happens — a confident mismatch breaks the chain
in ~3 frames, or an ambiguous one starts a 5 s clock (`unconfirmedLimit`) after
which presence stops advancing. Capping *unjudgeable* continuity as well would
trade that for locking out an owner turned toward a second monitor, which is why
turned-away faces and torsos are deliberately left unbounded.

### 3. "Never Countdown" and a broken recognizer

**Status:** handled by a fallback. **Added:** v1.3.0.

With no overlay there is no Esc gesture, which is the only way out when
recognition has stopped matching you. One lock is harmless — you log back in.
The trap is being locked again seconds later, indefinitely, with no in-app way
to stop it.

So locks are counted when no successful match happened in between, and after
**2** of them a minimum 3 s countdown is restored regardless of the setting,
purely so the Esc gesture exists. The counter is persisted, because every
iteration of a lock loop passes through a screen lock and an in-memory count
would reset before it could notice.

**What to look for:** if recognition breaks, expect the first lock to be silent
and instant, then a short countdown to start appearing. Any successful match
clears the counter and instant locking resumes.

### 4. A camera failure recovers on its own, indefinitely

**Status:** fixed, then redesigned. **Redesigned:** after a second occurrence.

Two separate faults produced the same symptom — the app running while the camera
sat off.

*First:* a failure called `pause()`, which stamps the timestamp that makes a
**deliberate** pause survive until the next schedule boundary. A one-second
hiccup therefore disabled protection for hours.

*Second:* the replacement retried only three times (30 s / 60 s / 300 s) and then
gave up permanently. A camera held by another app for more than ~6 minutes —
Zoom, Photo Booth, or in the observed case a diagnostic — burned the ladder and
left the machine unprotected for the rest of the day.

Underneath both was a design flaw: **liveness was checked once, three seconds
after start, and assumed true forever.** A session that died later was invisible,
because the "has delivered a frame" flag was sticky.

*Third:* a screen lock stops the camera and every timer, and the only way back
was the `screenIsUnlocked` notification — best-effort, so a single dropped one
stranded the app with the screen unlocked and nothing running to notice.

Liveness is now a **continuously supervised invariant**, owned by a supervisor
that runs for the life of the app at 1 Hz and is never stopped by a state
transition — which is the point, since every previous cause was a transition
that stopped the thing meant to notice. `FaceMonitor` records the instant of
every frame; the supervisor asserts the gap is under 3 s, and separately that
the session's lock state and the app's state still agree. Frames arrive at the
sensor's own rate regardless of the analysis throttle, so a gap is unambiguous.
One rule covers "never came up" and "died later", and the grace-expiry path
shares it, so the two can't disagree.

Detection is centralised there; the **remedies** stay where they were, so the
retry ladder's backoff and the "never lock on evidence gathered while blind"
rule still apply. Liveness is judged on delivered frames rather than
`session.isRunning`, which reads false while the session configures and would
tear the camera down on every start.

On a stale camera the app now asks a different question: *was absence already
proven before we went blind?* If the grace period had already elapsed, that
evidence was gathered while we could still see, so it locks — once. Otherwise it
holds the screen, enters `cameraUnavailable`, and retries at 30 s / 60 s / then
every 5 minutes **forever**, because the reason to keep trying never expires.
Locking repeatedly because our own camera is broken is a trap, not protection.
The user is told once; after that the struck-through icon and status line carry
it.

**What to look for:** open Photo Booth, then Start Monitoring. Expect the
struck-through camera icon, one alert after ~6 minutes, and **no permanent
pause**. Quit Photo Booth and monitoring must resume on its own within 5 minutes,
with no click.

### 5. Main-thread stalls delay the lock

**Status:** inherent, measured.

Both deadlines fire on the main thread. When it's free they land within **5 ms**
of the configured instant (measured). If the main thread is blocked when a
deadline arrives, the timer fires late by the remainder of that stall — measured
at **+145 ms** for a deadline landing inside a 400 ms stall. This is a property of
main-thread scheduling, not of the timers, and was equally true of the previous
`Timer`-based implementation.

The app's own two worst offenders (`queue.sync` hops onto the camera queue, which
runs Vision plus Core ML) were removed in v1.2.1, so what's left is other
applications and system hitches.

**What to look for:** a lock landing visibly later than the countdown reached
zero, correlating with the machine being busy.

### 6. Photo or video spoofing

**Status:** cannot be fixed on this hardware. There is no liveness signal
available from an RGB webcam without depth. A photo of the owner can cancel a
countdown. This is presence tooling, not authentication — unlocking still needs
your password or Touch ID.

## Manual checklist

Run after any change to `MonitorCoordinator`, `FaceMonitor`, `PresenceTracker`
or the schedule. `./build.sh --install` first.

### Timing accuracy

- [ ] Grace 3 / countdown 3: cover the lens. Overlay appears ~2–3 s later
      (early by up to one sampling interval is expected — see README), digits
      count 3 → 2 → 1, screen locks. No "0" frame.
- [ ] Grace 1: same, overlay within ~0.7–1.0 s.
- [ ] Change Start Countdown After **while watching**: the next countdown uses
      the new delay immediately, not the old one.

### Presence

- [ ] Sit normally → status reads "Watching for you", no countdown.
- [ ] Turn fully to a second monitor for a minute → no countdown.
- [ ] Stand up and walk away → locks on schedule.
- [ ] **Second person needed:** you leave, a colleague sits and faces the
      screen → locks in about the same time as an empty seat.
- [ ] **Second person needed:** you stay in frame while a colleague uses the
      keyboard → *no* countdown, indefinitely.
- [ ] Head down at the keyboard, shoulders in frame → no countdown.

### Countdown & failsafes

- [ ] Let the overlay appear, then face the camera → cancels.
- [ ] Esc ×3 on one overlay, then **pass** Touch ID: monitoring pauses, menu
      reads "Re-Enroll to Resume", status reads "Paused (re-enrollment needed)".
- [ ] While in that state, wait for a schedule boundary / lock and unlock:
      monitoring must **not** resume on its own.
- [ ] Quit and relaunch: still "Re-Enroll to Resume" (the flag is persisted).
- [ ] Click it, **cancel** enrollment: still required, old profile still intact.
- [ ] Click it again, complete enrollment: flag clears and monitoring resumes.
- [ ] Countdown Duration → **Never Countdown**: presence lapse locks instantly
      with no overlay.
- [ ] Esc no longer cancels on the first press: the overlay stays and reveals
      "Press Esc 2 more times to verify it's you".
- [ ] Third press holds the countdown ("Verifying…") and prompts Touch ID —
      confirm the screen does **not** lock while the prompt is up.
- [ ] Dismiss that prompt: the countdown resumes from where it was and locks.
- [ ] **Never Countdown + broken recognition** (cover the lens, or enroll a
      photo of someone else): first lock is instant, and after the second a 3 s
      countdown appears so Esc ×3 becomes available again.

### Camera health

- [ ] Hold the camera open in another app (Photo Booth), then Start Monitoring:
      icon becomes a struck-through camera, status reads "Camera unavailable —
      retrying", and it must not lock. Quit Photo Booth: monitoring resumes on
      its own within ~30 s, with no click needed.
- [ ] Leave Photo Booth holding the camera through all three retries (~6.5 min):
      only then does it become a real "Camera failed to start" pause.
- [ ] Start, Pause, Start again within 3 s: **no** spurious camera-failure alert.
- [ ] External camera: unplug it mid-session, replug, Start again — recovers
      without relaunching.

### Schedule

- [ ] Menu shows the live schedule, e.g. "Active Hours (9:00 AM–8:00 PM, Mon–Fri)…".
- [ ] Set start == end → Save is **rejected** with an explanation.
- [ ] Untick every day → blocked; Save is rejected if it somehow gets that far.
- [ ] Set today inactive → status reads "Paused (Tue not active)".
- [ ] Overnight range (21:00–06:00) on a day whose *next* day is inactive:
      still monitoring after midnight.
- [ ] Pause manually mid-window → stays paused until the next boundary, across
      a lock/unlock cycle.

### Lock / unlock recovery

- [ ] Lock (⌃⌘Q) and unlock **five times in a row, quickly**. The camera must
      resume every time. The unlock notification is best-effort and dropping one
      used to strand the app with the camera off for good; the supervisor now
      re-derives lock state every second, so a dropped notification should cost
      at most ~1 s of delay rather than the session.
- [ ] Lock, wait for the display to sleep, wake and unlock: same expectation.
- [ ] While watching, lock via **Fast User Switching**: monitoring must stop
      (camera off) rather than keep watching behind a locked session.

### Enrollment

- [ ] Enroll from a cold launch **off hours** (session never started): preview
      appears, no black frame, no crash.
- [ ] Cancel during enrollment: previous profile still works.
- [ ] **All four stages advance**: straight, one turn, the other turn, head down.
      No stage sits at a partial percentage while you hold the pose it asked for.
- [ ] **Turn right first** on the "turn left" stage: it still advances, and the
      next stage then requires the left turn. The gates take two opposite turns
      in whichever order they come — the preview is mirrored, so the on-screen
      direction and the sign of yaw need not agree.
- [ ] **Recapture** from a later stage: progress drops by exactly that stage's
      samples, and the redone stage judges direction against the stage before it.
- [ ] Read the verification line's **worst pose** score (leave-one-out, so it is
      not flattered by the samples that built the profile). Below the match
      threshold means the owner's own weakest pose sits under the bar — lower
      `matchThreshold` rather than shipping that.
- [ ] If a stage stalls, read `~/Library/Logs/LockscreenDah/enrollment-poses.log`
      (angles only, survives Re-Enroll) before touching a gate constant.

### Panel layout

- [ ] Active Hours panel: seven day checkboxes and "All days" fit without
      clipping; ticking "Always on" greys out hours *and* days.
