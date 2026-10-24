# Discord-like P2P messenger. Linux/Android/Web. No own server.
External infra only: public STUN, Nostr relays, WS trackers (bootstrap/signaling).

## Stack
Flutter stable, Dart 3, flutter_webrtc, drift, riverpod, protobuf,
package:cryptography, melos monorepo. No Rust/FFI.

## Layout
packages/: core_domain, core_crypto, core_protocol, core_storage,
core_signaling, core_peer, core_sync, core_group, core_relay, core_media,
platform_{android,linux,web}; apps/app (UI)
Deps point down only: core_domain depends on nothing internal.
Package contracts: docs/packages/<name>.md (read via @ when touching it).
Current state: docs/STATE.md (read at session start).

## Hard rules (enforced by tool/guard.sh, run /check)
- core_* is pure Dart: no dart:io/html/ui, no flutter. Platform code only in platform_*.
- External things only behind interfaces: SignalingChannel, PeerLink, Transport,
  Relay, MediaTopology, EventStore, SecureKeyStore, ScreenCaptureSource.
  Each has an in-memory fake for tests.
- Every group-state event is Ed25519-signed and validated BEFORE applying.
  Group state = pure function of event set.
- Never invent crypto/protocols: package:cryptography only. Non-trivial
  design -> /design first.
- Domain: sealed classes/Result, not exceptions. No secrets in logs, no print().
- Never guess package APIs: read source in ~/.pub-cache/hosted/pub.dev/<pkg>-<ver>/lib
  (version from pubspec.lock) before using an API not already used in the repo.
- Identifiers in English, comments and docs in Russian.

## Response style
Small task: diff + 1-3 lines of notes. No restating the task.
Non-trivial: use /design, then /feature.
After finishing a task: update docs/STATE.md (max 3 lines changed).
