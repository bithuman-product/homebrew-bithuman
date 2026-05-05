<!--
SPDX-License-Identifier: Apache-2.0
title: bitHuman — on-device voice chat for macOS
maintainer: bitHuman Inc.
homepage: https://www.bithuman.ai
project_type: cli, swift-library
platform: macOS 26+, Apple Silicon
runtime: 100% on-device (no network calls, no API keys)
keywords: voice-chat, on-device, local-llm, voice-cloning, lip-sync, avatar, agents, swift, macos, privacy-first
-->

<p align="center">
  <a href="https://www.bithuman.ai">
    <img alt="bitHuman" src="https://www.bithuman.ai/og.png" width="220">
  </a>
</p>

<h1 align="center">bithuman-cli</h1>

<p align="center">
  <strong>Talk to your Mac. Or type. 100% on-device.</strong><br>
  Voice + lip-synced avatar chat — private, fast, no cloud.<br>
  Made by <a href="https://www.bithuman.ai">bitHuman</a>.
</p>

<p align="center">
  <a href="#install"><img alt="brew install" src="https://img.shields.io/badge/brew-install%20bithuman--cli-orange?style=flat-square"></a>
  <a href="#"><img alt="macOS 26+" src="https://img.shields.io/badge/macOS-26%2B-blue?style=flat-square"></a>
  <a href="#"><img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-only-green?style=flat-square"></a>
  <a href="LICENSE"><img alt="Apache 2.0" src="https://img.shields.io/badge/license-Apache%202.0-lightgrey?style=flat-square"></a>
</p>

---

## What it does

`bithuman-cli` turns your Mac into a real-time conversational assistant.
Speak, type, or both — it transcribes, thinks, and replies out loud. In
**video mode**, a small floating face in a circular window moves its
lips in sync with the bot's voice. You can interrupt mid-sentence and
it cuts off within ~50 ms.

**Everything runs locally.** No data leaves your machine. No API keys.
No cloud round-trip. Works offline once the models are cached.

> Previously known as `bitchat`. If you have the old formula installed,
> run `brew uninstall bitchat && brew untap bithuman-product/bitchat`,
> then follow the install steps below.

## Install

Requires **macOS 26 (Tahoe) or later** on **Apple Silicon (M3+)** — the avatar engine refuses pre-M3 silicon at runtime.

```sh
brew tap bithuman-product/bithuman
brew install bithuman-cli
bithuman-cli                  # voice (default)
bithuman-cli video            # voice + animated face
```

That's it. First launch downloads the models (a few GB depending on mode)
to `~/.cache/huggingface/hub/`. Every launch after is offline.

## Three modes

| Mode | What you get | First-run download |
|---|---|---|
| `text` | Typed chat in the terminal. Pipe-friendly: `echo "hi" \| bithuman-cli text`. | ~2 GB |
| `voice` *(default)* | Spoken conversation through your speakers. Voice cloning from a 10 s clip. | ~3 GB |
| `video` | Voice + a floating circular window with a talking face. 8 bundled agents, drop-in face swap, voice gallery, prompt editor. | ~7 GB |

```sh
bithuman-cli                                  # voice — pure audio chat
bithuman-cli text                             # text-only repl
bithuman-cli video                            # video chat with the default agent
bithuman-cli video --image ~/Desktop/me.jpg   # video chat with your face
```

## ✨ Video mode — the centerpiece

`bithuman-cli video` opens a small floating circular avatar window.
**Right-click the avatar** to customize.

### 8 bundled agents

Pick a persona and the avatar's portrait, voice, and personality all swap
together. **Diego** is the default for fresh users — laid-back, neutral,
easy to talk to.

| Agent | Vibe |
|---|---|
| **Diego** | laid-back roommate coach |
| **Nova** | energetic millennial storyteller |
| **Einstein** | warm physics mentor with simple analogies |
| **Riya** | confident-interview communication coach |
| **Lena** | bold stand-up comic for stage-presence drills |
| **Rae** | charismatic late-night talk-show host |
| **Dr. Maya** | seasoned ethics advisor |
| **Mason** | calm pricing strategist for creators |

### Customize anything

Right-click the avatar window:

- **Choose agent…** — 2-column gallery; click a card to apply.
- **Change image…** — pick a portrait from disk **or just drag-drop it
  onto the avatar**. The face animates through your portrait after a
  ~5 s encode.
- **Change voice…** — gallery of 9 voices grouped Feminine / Masculine.
  Click any card to audition; **Save** commits.
- **Change prompt…** — clean editor with 6 starter templates (Companion,
  Coach, Tutor, Storyteller, Coding buddy, Calm listener). Tweak before
  saving.

### Status at a glance

A colored ring around the avatar tells you what it's doing:

| Color | State |
|---|---|
| 🩵 cyan | listening |
| 🟣 violet | thinking |
| 🟠 amber | speaking |

A label below echoes the same.

### Quiet by design

The avatar holds its idle motion via a small in-memory loop — after ~10 s
of warm-up the GPU drops to near-zero usage until you speak again. Leave
bithuman-cli running for hours without spinning the fans or draining the
battery.

## Talk *or* type

Speak after `🎙️ Listening`. Or just **type a message in the terminal and
hit Enter** — handy when the room is loud or you want to be precise. Both
go through the same turn flow; the bot replies the same way.

Cut in by speaking while the bot is replying — it stops within ~50 ms
(audio + avatar both). Cmd-Q, Ctrl-C, or right-click → "Quit bitHuman"
all shut down cleanly.

## Quick start

```sh
bithuman-cli voice --voice Aiden              # voice mode: Qwen3 preset speaker
bithuman-cli voice --voice ~/voices/me.wav    # voice mode: clone your own voice (auto-transcribed)
bithuman-cli video --voice am_michael         # video mode: Kokoro preset speaker
bithuman-cli voice --locale ja-JP             # listen + reply in Japanese
bithuman-cli text --prompt "Be a deadpan ship's computer."
bithuman-cli video --image ~/Desktop/me.jpg   # your face, default voice
echo "summarise this:" | bithuman-cli text    # use as a shell pipe
```

| flag | what it does |
|---|---|
| `--locale <bcp47>` | ASR + TTS language (default `en-US`). Examples: `en-US`, `ja-JP`, `zh-CN`, `es-ES`, `fr-FR`. |
| `--voice <preset\|path>` | Pick the bot's voice. Accepted values differ by mode (the two modes use different TTS engines): **voice mode** takes a Qwen3 preset (`Ryan`, `Aiden`, `Vivian`, `Serena`, `Uncle_Fu`, `Dylan`, `Eric`) **or a path** to a 10–20 s mono audio file, which is cloned and auto-transcribed. **video mode** takes a Kokoro preset only (`af_heart`, `af_alloy`, `af_aoede`, `af_kore`, `am_adam`, `am_michael`, `am_echo`, `bf_emma`, `bm_george`); cloning isn't supported in video mode (the avatar engine needs the GPU, so video uses a smaller TTS that doesn't clone). |
| `--image <preset\|path>` | (video mode) Bundled portrait preset (`Alice`, `Marco`, `Captain`, `Nia`, `Riley`) or a path to JPG/PNG/HEIC. Defaults to the active agent's portrait. |
| `--prompt <text\|@path>` | Override the system prompt. Inline string or `@/path/to/file.txt`. |
| `-h`, `--help` | Show usage. |

## Why bitHuman?

- **Truly local.** No API keys, no per-token billing, no audio leaving
  your Mac. If your laptop's offline, bithuman-cli still works.
- **Real-time, with barge-in.** The bot stops within ~50 ms of you
  starting to speak — both audio and the avatar's mouth.
- **Voice cloning out of the box.** Drop in a 10-second clip and
  bithuman-cli uses it as the bot's voice (voice mode).
- **Drop-in face swap.** Drag any portrait onto the avatar and it
  becomes the new face after a quick on-device encode (video mode). No
  retraining, no upload.
- **Quiet when idle.** The fans don't spin while you're not talking.
- **Apache 2.0** code + bundled model weights.

## What's powering it

| | Layer |
|---|---|
| Speech-to-text | Apple's built-in `Speech` framework |
| Language model | Local 2-billion-parameter LLM (4-bit quantized) |
| Voice synthesis | Two local TTS engines: Qwen3-TTS in voice mode (voice-cloning capable), Kokoro in video mode (preset voices only — lighter, coexists with the avatar GPU pipeline) |
| Avatar animation | bitHuman expression engine (lip-sync at 25 FPS) |

Working set on a 24 GB M-series MacBook Pro:

- text mode: ~2.5 GB
- voice mode: ~4 GB
- video mode: ~8 GB

No swap pressure during normal conversation in any mode.

## For developers

bithuman-cli ships as a Swift library too — `bitHumanKit` — embeddable
via Swift Package Manager. Build a custom voice / video assistant in a
few lines:

```swift
import bitHumanKit

var config = VoiceChatConfig()
config.localeIdentifier = "en-US"
config.systemPrompt = "You are a deadpan ship's computer. One sentence."
config.voice = .preset("Aiden")
// or .clone(referenceAudio: someURL, transcript: "...")

let chat = VoiceChat(config: config)
try await chat.start()

// Optional: drive a SwiftUI avatar window
// (see the dev repo for the FramePump + AvatarWindow setup)
```

Library access is currently invitation-only while the SDK stabilises.
Open an issue at
[bithuman-product/homebrew-bithuman/issues](https://github.com/bithuman-product/homebrew-bithuman/issues)
if you'd like access.

## Tips

- **Set `BITHUMAN_VERBOSE=1`** in your shell if you want to see
  model-loading internals (tensor counts, dtype breakdowns) while
  debugging. Silent by default.
- **First launch downloads ~3–7 GB of models** depending on mode. Plan
  for it on a slow connection — the rest of bithuman-cli then works
  offline.

## About bitHuman

bithuman-cli is built and maintained by
[**bitHuman**](https://www.bithuman.ai), the team behind real-time
on-device avatar engines. We make local-first voice and avatar AI feel
as good as the cloud services you're used to — without sending your
audio anywhere.

bithuman-cli is one piece of the bitHuman product family, alongside the
Halo desktop and iPad companion apps.

- 🌐 [www.bithuman.ai](https://www.bithuman.ai)
- 📦 [github.com/bithuman-product](https://github.com/bithuman-product)
- 🪟 Halo (full desktop companion app):
  [github.com/bithuman-product/bithuman-halo-macos](https://github.com/bithuman-product/bithuman-halo-macos)

## Contributing & source

This repo (`bithuman-product/homebrew-bithuman`) hosts the **release artefacts**: the Homebrew formula and notarised binaries. The Swift source for the underlying SDK is private; the public binary distribution lives at [`bithuman-sdk-public`](https://github.com/bithuman-product/bithuman-sdk-public). Use that to embed the SDK in your own app.

## Docs

Full SDK and CLI documentation: **[docs.bithuman.ai](https://docs.bithuman.ai)**.

- [bithuman-cli reference](https://docs.bithuman.ai/swift-sdk/cli)
- [Swift SDK overview](https://docs.bithuman.ai/swift-sdk/overview) — embed in your own Mac/iPad/iPhone app
- [Authentication](https://docs.bithuman.ai/getting-started/authentication) — only needed for avatar mode (audio-only is unmetered, no key required)
- [Pricing & credits](https://docs.bithuman.ai/getting-started/pricing)

## Agents and LLMs

This repo publishes [`llms.txt`](llms.txt) — a structured manifest aimed
at AI coding assistants discovering and using bithuman-cli. Agents
trying to install or invoke bithuman-cli on a user's machine should
start there.

## License

Apache 2.0. See [`LICENSE`](LICENSE).

---

<p align="center">
  Made with ❤️ by <a href="https://www.bithuman.ai"><strong>bitHuman</strong></a>.<br>
  <sub>Local-first voice & avatar AI for the post-cloud era.</sub>
</p>
