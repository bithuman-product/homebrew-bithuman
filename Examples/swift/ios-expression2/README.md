# ios-expression2 — a talking bitHuman avatar on the iPhone you already have

A complete SwiftUI app that renders a lip-synced **expression-2** avatar
**on the device**, at 416x720, 25 FPS, with no server in the loop.

It is deliberately the *cheap* Apple path:

| | this example | [`ios-avatar`](../ios-avatar) (the `bitHumanKit` umbrella) |
|---|---|---|
| device floor | none — measured on an **iPhone 15** | iPhone 16 Pro or later |
| Apple entitlements | none | two, 1–3 business days to approve |
| first-launch download | none (the model ships in the app) | ~1.6 GB |
| what drives it | a bundled WAV, or your microphone | on-device STT + LLM + TTS |

The **Speak** path is what every number below was measured on. The **Talk to
it** (microphone) path builds and installs with it but was never driven by a
human voice on a device — it is a fifteen-line starting point, not a measured
result.

The full tutorial, with every file explained, is at
<https://docs.bithuman.ai/examples/swift-ios-expression2>.

## What you need

- A Mac with **Xcode 26+**, and an Apple Developer team.
- A **physical iPhone or iPad** with Apple Silicon. The Simulator cannot run
  this engine.
- An **expression-2 agent of your own** and your API secret. The app renders
  *your* identity; there is no public expression-2 identity to point it at.
- The bitHuman CLI, for one 91 MB download:
  `brew install bithuman-product/bithuman/bithuman-cli`

## Run it

```bash
git clone https://github.com/bithuman-product/homebrew-bithuman.git
cd homebrew-bithuman/Examples/swift/ios-expression2

# 1. fetch the three payload files into Sources/Model/
BITHUMAN_API_SECRET=… ./setup.sh <YOUR_AGENT_CODE>

# 2. open it, pick your team under Signing & Capabilities, pick your iPhone, Run
open IOSExpression2.xcodeproj
```

`setup.sh` puts three things in `Sources/Model/`:

| file | where it comes from | why |
|---|---|---|
| `agent.avatar` | `GET /v1/agent/{code}/model/download?model=expression-2` | your identity |
| `shared_engine/` | `bithuman engine install mac` | the artifact does **not** carry `w2v_frontend_cpuAndNE.mlpackage`; this directory does |
| `speech16k.wav` | macOS `say` + `afconvert` | something for it to say |

None of them is committed — the payload is yours, and `.gitignore` keeps it out.

## Two things you should know before you build

1. **The one-call container path does not work on iOS yet.** Through
   `Expression2` 2.11.2 the shipped
   `Expression2Engine.create(avatarContainer:…:stagingDir:)` refuses a published
   `.avatar` on iOS by member name. This app therefore stages the members itself
   with `Expression2Container.read`, which does not. That is the loop in
   `Renderer.load`, and it is a few lines. The root fix is on the SDK's `main`
   and reaches you when the framework is rebuilt and a new tap tag is cut.
2. **`pull()` is asynchronous.** It returns `nil` until a chunk of frames lands,
   so a bare `while let (frame, _) = engine.pull()` on the line after `feed()`
   drains nothing and your view stays empty. Poll, and feed and drain at the
   same time — see the comment in `speak()`.

## Measured

On an iPhone 15 (iPhone15,4), iOS 26.6.1, built with Xcode 26.3 on
macOS 26.6.2, 2026-09-09:

```
[ios-expression2] engine ready: 14 members staged · 416x720 · isReady=true in 7.3s
[ios-expression2] audio 16 kHz mono: 83797 samples, 5.24 s
[ios-expression2] generated 117 frames at 416x720 in 2.62 s (44.6 FPS, 2.00x real time)
[ios-expression2] first frame 416x720 written to Documents/first-frame.png (771436 B)
[ios-expression2] played 117 frames in 4.68 s (25.0 FPS) beside 5.24 s of audio
```

The frame pulled off the phone reads 416x720, min 0, max 255, mean 92.66 — a
picture, against an all-black buffer of the same size that the same check calls
flat in the same run. First launch spends most of those 7.3 s compiling CoreML
graphs on the device; later launches were 1.7 s.

Pull that frame off the phone with:

```bash
xcrun devicectl device copy from --device <udid> \
  --domain-type appDataContainer \
  --domain-identifier ai.bithuman.example.ios-expression2 \
  --source Documents/first-frame.png --destination ./first-frame.png
```

## Files

```
setup.sh                 fetches the payload
project.yml              xcodegen source for IOSExpression2.xcodeproj (optional)
Sources/App.swift        the whole app — engine, audio, view
Sources/Info.plist       one privacy string, for the microphone button only
Sources/Model/           the payload (git-ignored)
```
