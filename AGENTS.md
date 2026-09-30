# homebrew-bithuman — guide for AI agents

This repository is two things:

- **The bitHuman Apple SDK**, a Swift package (`Package.swift` at the root). It renders real-time, lip-synced avatars on iPhone, iPad and Mac: Essence 2 (a photoreal person) and Expression 2 (any character). Your app passes in 16 kHz mono speech from any voice stack and draws the frames the engine returns. The SDK renders only; the conversation (speech recognition, language model, voice) comes from the developer's own services.
- **The Homebrew tap and release artefacts for the `bithuman` CLI** (`Formula/`, `install.sh`, the `cli-v*` releases).

Read facts from the docs, not from memory or from this file. The docs are generated from the published artifacts:

- Agent entry point: https://docs.bithuman.ai/llms.txt (and https://docs.bithuman.ai/llms-full.txt)
- Current version of every package: https://docs.bithuman.ai/versions.json
- Prices: `GET https://api.bithuman.ai/v1/pricing`, or https://docs.bithuman.ai/pricing
- Speed: https://docs.bithuman.ai/performance.json (× real time, per device)

## Which path

| The user wants | Use | Docs | Example |
|---|---|---|---|
| An iPhone or iPad app | Swift package: `Expression2` or `Essence2Kit` | https://docs.bithuman.ai/platforms/ios | https://github.com/bithuman-product/bithuman-examples/tree/main/swift |
| A Mac app | the same Swift package | https://docs.bithuman.ai/platforms/macos | `swift/macos-expression2` in bithuman-examples |
| An Android app | maven.bithuman.ai (bitHuman's Maven repository): `ai.bithuman:expression2-android`, `ai.bithuman:essence2-android` | https://docs.bithuman.ai/platforms/android | `android/` in bithuman-examples |
| A live avatar from the terminal, no code | the CLI | https://docs.bithuman.ai/platforms/cli | `api/cli/` in bithuman-examples |
| Frames or MP4s from Python | `pip install bithuman` | https://docs.bithuman.ai/platforms/python | `python/quickstart/` in bithuman-examples |
| A face for a LiveKit voice agent | `livekit-plugins-bithuman` | https://docs.bithuman.ai/platforms/livekit | `python/` in bithuman-examples |
| An avatar on a web page | one iframe | https://docs.bithuman.ai/platforms/web | — |
| Any backend, over HTTPS | the REST API | https://docs.bithuman.ai/platforms/rest | `api/rest-api/` in bithuman-examples |

Examples live in https://github.com/bithuman-product/bithuman-examples. This repository's `Examples/` holds only a README that points there.

## Swift package

```swift
// Package.swift — take the version from https://docs.bithuman.ai/versions.json ("swift")
.package(url: "https://github.com/bithuman-product/homebrew-bithuman.git", from: "<version>")
// then attach one product:
//   .product(name: "Expression2", package: "homebrew-bithuman")
//   .product(name: "Essence2Kit", package: "homebrew-bithuman")
//   .product(name: "Essence2", package: "homebrew-bithuman")   // the C interface
```

| Product | Import | Deployment target |
|---|---|---|
| `Expression2` | `import Expression2` | iOS 16 · macOS 13 |
| `Essence2Kit` | `import Essence2Kit` | iOS 26 · macOS 26 |
| `Essence2` | `import Essence2` | iOS 26 · macOS 26 |

- `bitHumanKit` 2.4.0 is legacy and frozen. Do not start a new app on it.
- Do not add `BithumanEngineProtocol` beside `Expression2`; `Expression2` carries its own copy.
- Essence 2 needs a physical device; it does not run in the Simulator. Expression 2 runs in both.
- Each session needs an API secret: `Expression2Credential.set(secret)` or `Essence2Credential.set(secret)`.

## Rules

- **Plan.** From 12 October 2026, API and SDK use requires the Creator plan or higher. Never tell a user they can build on a free plan.
- **Billing.** Sessions bill active session time, talking or idle, to the second. Quote rates only from `/v1/pricing` or the docs pricing page.
- **The API secret.** One credential for every surface, `BITHUMAN_API_SECRET`. Keep it in the environment or the Keychain, never in source, argv or a build flag. An app you distribute holds the secret on every device, so fetch it from your backend at startup, use a separate secret per app, and rotate it if usage looks wrong. In a LiveKit worker, name it `BITHUMAN_MASTER_SECRET` and pass a minted token (https://docs.bithuman.ai/platforms/livekit).
- **Where things happen.** Say where the avatar renders (device, browser, your server, or the bitHuman cloud) and where the conversation runs (your stack, the CLI's local conversation brain, or bitHuman's servers). Phones, Macs and browsers stay online: a session checks the credential when it starts.
- **Versions.** Never write a version from memory; read `versions.json`, the tap's tags (`git ls-remote --tags`), PyPI or maven.bithuman.ai (`ai.bithuman/<artifact>/maven-metadata.xml`).
- **The CLI is not on PyPI.** `pip install bithuman` is the Python library and puts no `bithuman` command on PATH. Install the CLI with `brew install bithuman-product/bithuman/bithuman-cli` (macOS) or `curl -fsSL https://install.bithuman.ai | sh` (macOS, Linux).

## Working in this repository

- `Package.swift` is resolved by bare `v*` tags. Its binary targets, URLs and checksums change only in a release; `scripts/check-manifest-truth.py` checks them against the published bytes.
- Release tags and what each one ships: [RELEASE.md](RELEASE.md).
- `scripts/guard-public-vocabulary.py` keeps internal vocabulary out of this public repository; run it before you push.
