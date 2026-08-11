# Testing & watch list

`swift test` covers `PresenceTracker`, `Settings`, `MonitoringSchedule` and
`CameraRestPolicy` — the pure logic where every presence and timing bug in this
project has actually lived. Everything below is
what a test **can't** reach: it needs a real camera, a real face, and in a couple
of cases a second person.

## Watch list

Known-risk behaviours that are deliberately allowed rather than fixed. Each one
says what to look for, so a report is "I saw X" rather than "it feels off".

### 1. Overlay flash after a typing pause at a 1 s countdown delay

**Status:** allowed, on watch. **Introduced:** v1.3.0 (idling became available at
every delay).

Camera idling stops the capture session outright. Waking is an identity gate, so
you must land one fresh face match inside the countdown delay or the overlay
appears. Session spin-up itself no longer counts against the delay — the clock
starts at the first delivered frame — but auto-exposure is re-converging from
cold, so the first frame or two can be unusable. At a 1 s delay that leaves
roughly three attempts.

**What to look for:** a brief full-screen blackout, one to two seconds after you
stop typing, that cancels itself once your face is recognised. With the forced
wake disabled (entry 2), this can only happen on a genuine typing pause, and
`cameraMinAwake` (20 s) bounds it to at most one occurrence per ~20–30 s.

**If it happens:** raise Start Countdown After to 3 s, or set Idle When Typing
For to **Never Idle**. If it happens often, `cameraRestMinimumGrace` in
`Settings.swift` should go back to 3.

### 2. Blind window while the camera is idling — UNBOUNDED

**Status:** accepted, unbounded. **Decided:** v1.3.0, after measuring the cost of
the alternative.

While resting, the camera is **stopped** and presence is asserted by keystrokes
alone. The dangerous property is that an intruder's own activity *sustains* the
blindness rather than ending it: holding a key keeps input flowing, which is
exactly what keeps the camera asleep. Their face costs them nothing, because
nothing is watching. This is why the "they have to look at the screen" reasoning
that covers entry 3 does **not** cover this one.

**The concrete attack:**

1. You're typing; the chain is established; the camera rests.
2. You walk away. An intruder holds a key within the wake threshold (1–5 s).
3. `presence.touch()` keeps firing on input alone — the camera never reopens.
4. They use the machine freely, facing the screen or not.

**Why it isn't capped.** A 10 s ceiling with a 2 s "peek" was built and measured:
it bounds the window, but it reopens the camera roughly every 10 s forever, giving
a ~10–18% duty cycle against ~0% while resting, and re-running auto-exposure each
time. That cost was judged not worth paying continuously for a threat that needs
an attacker physically holding a key during a narrow handover. The machinery is
still in the code — set `cameraRestMaxDuration` in `MonitorCoordinator.swift`
above 0 to switch it back on.

**The tradeoff, stated plainly:** camera idling trades an unbounded blind window
for near-zero CPU. There is no middle setting that avoids both.

**If your threat model doesn't accept that:** set Idle When Typing For to
**Never Idle**. The camera then watches continuously — no blind window at all —
at a steady ~8–9% of one core. That is the supported answer to this risk.

### 3. Stranger who never faces the camera

**Status:** accepted. Rationale below.

Body detection (`VNDetectHumanRectanglesRequest`) answers "is a person there",
never "which person" — a torso carries no identity signal, and it only runs on
frames with no face at all. So a torso in frame maintains the chain with no time
cap, and the stranger challenge can't help because it only judges near-frontal
faces.

**Why this is accepted rather than capped:** an intruder has to *look at the
screen* to do anything with the machine. The moment they do, the frontal check
fires and the chain breaks within ~3 frames. Capping body-only continuity would
trade that for locking out an owner legitimately turned toward a second monitor.

### 4. "Never Countdown" and a broken recognizer

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

### 5. A camera failure recovers on its own

**Status:** fixed. **Added:** after a real incident — the app sat unprotected for
hours and reported "Camera failed to start".

A camera that fails to deliver frames used to call `pause()`, which stamps
`lastDecisionAt`. That stamp is what makes a *deliberate* pause survive sleep and
lock until the next schedule boundary — correct for a user's choice, badly wrong
for a hardware stumble. A one-second hiccup at 09:05 therefore disabled
protection until 20:00, with only a dismissible modal as evidence.

Now a failure enters `.cameraUnavailable` and retries after 30 s, 60 s, then
300 s, without consuming a schedule decision. Any delivered frame resets the
count. Only after all three retries fail does it become a real pause with an
alert. The menu-bar icon shows a struck-through camera throughout and the status
line reads "Camera unavailable — retrying", so it can never be mistaken for an
ordinary pause.

**What to look for:** open Photo Booth (taking the camera), then Start
Monitoring. Expect the struck-through icon and a retry roughly 30 s later, not an
immediate permanent pause. Quit Photo Booth and monitoring should resume by
itself within a couple of minutes.

### 6. Main-thread stalls delay the lock

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

### 7. Photo or video spoofing

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

### Camera idling

- [ ] Type steadily for `cameraRestAfter` seconds: icon changes to 💤 and the
      camera LED goes out.
- [ ] Pause typing: camera reopens, and you're re-matched without a blackout.
- [ ] **Hold a key down for 30 s** (this is watch-list entry 2): the icon stays
      💤 and the LED stays off for the whole time. That is the accepted, unbounded
      blind window — it is *expected* here, not a bug. If the forced wake is ever
      re-enabled, this is the check that should start alternating instead.
- [ ] Set **Never Idle**: icon stays on the face icon, never 💤, LED stays on.

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

### Enrollment

- [ ] Enroll from a cold launch **off hours** (session never started): preview
      appears, no black frame, no crash.
- [ ] Cancel during enrollment: previous profile still works.

### Panel layout

- [ ] Active Hours panel: seven day checkboxes and "All days" fit without
      clipping; ticking "Always on" greys out hours *and* days.
