## Unreleased

* **Account hub + `engine/sdk/app` reorg + dead-code cleanup.** All chrome
  consolidated behind one top-left Clerk avatar → a single in-app **hub**:
  profile · credits (on-device **1 cr/min** vs OpenAI **10 cr/min**, 99 free
  credits/mo, Upgrade) · avatar gallery · runtime · voice · personality ·
  password · sign out · quit. Real Clerk account management via public
  `ClerkAuthState` APIs only — custom UI, no prebuilt widgets, so the OAuth
  deep-link issue stays sidestepped. A typed message now **barges** like a
  spoken turn, and the voice-processing unit no longer **ducks other apps'
  audio** (macOS 14+). The repo was reorganized into
  `engine / sdk / app / training / inference` (the Flutter plugin split into
  `sdk/` + the product app, since spun out to the standalone `bithuman-app`
  repo), and ~1.5k lines of dead UI code from the
  refactor were removed. (Follow-up: retire the orphaned detached-settings
  window subsystem.)

* **embody-apple native macOS app — self-contained, embody-only, multi-agent.**
  The Flutter app is now an **embody-only** Apple-Silicon talking-head app
  (avatar = pure-Swift/CoreML `Expression2Runtime`; brain = OpenAI Realtime *or*
  on-device libconverse). The `essence`/`elevate` engines were removed (−1926
  lines). It is **self-contained under `embody/`**: `scripts/bootstrap.sh` fetches
  the `vendor-v1` GitHub release (`embody-vendor.tar.gz` = libconverse.xcframework
  + A42 CoreML models), sha256-verifies it, and a Runner build phase bundles the
  models into the `.app` (no sibling SDK / no `~/embody-ane` needed).
  * **Downloadable agent gallery (8 identities).** A Supabase manifest +
    per-identity `~88 MB` bundles (student + audiotokenizer + canon + idle.mp4);
    `Expression2Runtime.activeAgentDir` loads per-agent weights while the shared
    w2v/taehv graphs ship once in the app. Switching also applies a gender-matched
    voice + persona.
  * **Per-agent idle video.** Each agent idles *as itself* (server-rendered, or a
    Seedance clip from the source image cropped to the 416×720 framing). Fixes the
    "every agent idled as Einstein" bug — `resURL` no longer falls back to the
    bundled A42's `idle.mp4`/`canon` for a downloaded agent.
  * **Sharp render from frame 0 (speech-warm seed).** The first reply of every
    non-A42 agent used to render *warped/soft* for ~15-20 s then sharpen: the
    per-utterance reset seeded the ctx ring with the *silence-rest* state (≈base
    identity), which takes ~20 s of audio to diffuse to the identity's speaking
    look. Fix: at warm-up, feed a short generic-speech clip (`embody/warm.wav`,
    synthesized by `bootstrap.sh` via macOS `say`) through the model so the captured
    reset seed is the **speaking-converged** state — sharp from frame 0, full ANE
    speed. (fp32 is too slow to ship; canon-seed renders the base identity and never
    converges.) Onset sharpness (var-of-Laplacian) ~95 → ~200.
  * **Audio robustness:** Bluetooth/loudspeaker hot-swap (Core Audio HAL
    listeners), device-switch crash fixed (Obj-C `@try/@catch` shim around
    `installTap`), mic-permission gate, VP-IO/AEC so the agent doesn't interrupt
    itself, local-mode barge, and a tail-flush so the last word isn't clipped.

* **embody (on-device CoreML) — clean speech onset, exact A/V sync, instant barge.**
  Brought the Apple/CoreML `embody` engine to parity with the server's clean onset
  (`Expression2Runtime.swift`):
  * **No onset "snowflake".** The first chunk (`ci=0`) of each response was a cold
    wav2vec2 window with no left context → ~1 s of static that "converged" to the
    face. It now prepends a 6-**token** silence left-context margin to that window and
    shifts `base` past it, so it emits the *same* first-second content but computed
    warm — identical A/V, no static. (Token units, not frame units: the
    audiotokenizer downsamples the 55-frame w2v window ~4× to 14 tokens, so the margin
    is `onsetBase · WIN_LAT·SPF / numTokens` ≈ 18857 samples; `numTokens` is captured
    from the model at warm-up.)
  * **Exact A/V sync.** Speaker audio is metered 50 ms per published lip-frame
    (count-based pairing), and each response resets the engine stream so frame N maps
    1:1 to its audio. (A continuous-stream experiment that desynced this — and
    re-animated the previous sentence at each onset — was reverted.)
  * **Instant clean barge.** `resetState()` bumps a generation counter, so an
    in-flight background `processChunk` discards its frames instead of appending
    ~1.6 s of stale animation after an interrupt — the avatar snaps back to the idle
    video immediately, with the audio queue cleared.
  * Also on this branch: **USM unsharp-mask sharpen** (`EMBODY_SHARPEN`, GPU-parity
    crispness), a **detached Flutter settings window**, and a **macOS-26 local-mode
    gate** (`isLocalModeSupported`).

* **Engine bumped to 2.3.3** — Android `ai.bithuman:sdk` 1.16.0 → 2.3.3 (ABI 7;
  API verified source-compatible). iOS/macOS build against the current
  libessence (2.3.3) via the sibling SDK + the fixed Flutter bootstrap. Plugin
  version → 2.3.3. (Per-platform build/run verification pending.)

* **Migrated to OpenAI Realtime GA** — the beta endpoint was retired
  upstream and now refuses connections with close code 4000
  (`invalid_request_error.beta_api_shape_disabled`). Changes:
  * Drop the `OpenAI-Beta: realtime=v1` header.
  * Default `model` flipped from `gpt-4o-realtime-preview-2024-12-17`
    to `gpt-realtime`.
  * `session.update` payload rewritten to the GA shape: top-level
    `type: 'realtime'`, `output_modalities: ['audio']`, audio config
    nested under `audio.input` / `audio.output`, `voice` lives inside
    `audio.output`, `turn_detection` inside `audio.input`, format
    object `{type: 'audio/pcm', rate: 24000}` (was the string `'pcm16'`).
  * Inbound event renames: `response.audio.delta` →
    `response.output_audio.delta`, and `response.audio_transcript.delta`
    → `response.output_audio_transcript.delta`.
* **Reconnect-backoff fix** — the WebSocket reconnect counter now resets
  on the first inbound server event rather than on TCP-dial success.
  Without this, server-side close-after-handshake (auth rejected, schema
  rejected, beta deprecation) looped forever in `connecting` instead of
  surfacing `RealtimeStatus.error`; the max-retries ceiling was
  unreachable because every dial reset the counter to zero.

