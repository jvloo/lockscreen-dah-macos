# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/jvloo/lockscreen-dah-macos/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/jvloo/lockscreen-dah-macos/releases/tag/v1.0.0
