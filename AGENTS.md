# homebrew-bithuman — guide for AI agents

This repository is **the Homebrew tap and the installers for the `bithuman` CLI** (`Formula/`, `Aliases/`, `install.sh`, `install.ps1`, and the tooling that publishes `cli-v*` releases to https://downloads.bithuman.ai/homebrew-bithuman). Install the CLI with `curl -fsSL https://install.bithuman.ai | sh` (recommended) or `brew tap bithuman/bithuman https://gitlab.com/bithuman/sdk/homebrew-bithuman && brew install bithuman-cli`, always with the tap's URL.

The SDKs live in their own projects: Swift in https://gitlab.com/bithuman/sdk/bithuman-swift (3.0), Flutter in https://gitlab.com/bithuman/sdk/bithuman-flutter (pub.dev `bithuman` 3.0), Android from https://maven.bithuman.ai. `Package.swift` and `Sources/` stay here only so already-released Swift 2.x builds keep resolving; never point SwiftPM at this repository.

Read facts from the docs, not from memory or from this file. The docs are generated from the published artifacts:

- Agent entry point: https://docs.bithuman.ai/llms.txt (and https://docs.bithuman.ai/llms-full.txt)
- Current version of every package: https://docs.bithuman.ai/versions.json
- Prices: `GET https://api.bithuman.ai/v1/pricing`, or https://docs.bithuman.ai/pricing
- Speed: https://docs.bithuman.ai/performance.json (× real time, per device)

## Which path

| The user wants | Use | Docs | Example |
|---|---|---|---|
| An iPhone or iPad app | the Swift package, https://gitlab.com/bithuman/sdk/bithuman-swift | https://docs.bithuman.ai/platforms/ios | https://github.com/bithuman-product/bithuman-examples/tree/main/swift |
| A Mac app | the same Swift package | https://docs.bithuman.ai/platforms/macos | `swift/macos-expression2` in bithuman-examples |
| A Flutter app (Android, iOS, macOS) | `bithuman: ^3.0.0` from pub.dev | https://docs.bithuman.ai/platforms/flutter | on the docs page |
| An Android app | maven.bithuman.ai (bitHuman's Maven repository): `ai.bithuman:bithuman-android` 1.0 with `ai.bithuman:bithuman-bom` | https://docs.bithuman.ai/platforms/android | `android/` in bithuman-examples |
| A live avatar from the terminal, no code | the CLI | https://docs.bithuman.ai/platforms/cli | on the docs page |
| Frames or MP4s from Python | `pip install bithuman` | https://docs.bithuman.ai/platforms/python | `python/quickstart/` in bithuman-examples |
| A face for a LiveKit voice agent | `livekit-plugins-bithuman` | https://docs.bithuman.ai/platforms/livekit | `python/` in bithuman-examples |
| An avatar on a web page | one iframe | https://docs.bithuman.ai/platforms/web | — |
| Any backend, over HTTPS | the REST API | https://docs.bithuman.ai/platforms/rest | on the docs page |

Examples live in https://github.com/bithuman-product/bithuman-examples. This repository's `Examples/` holds only a README that points there.

## Swift package 2.x (critical fixes only)

New apps use Swift 3.0 from https://gitlab.com/bithuman/sdk/bithuman-swift:

```swift
// Package.swift — take the version from https://docs.bithuman.ai/versions.json ("swift")
.package(url: "https://gitlab.com/bithuman/sdk/bithuman-swift", from: "3.0.0")
```

Apps on 2.x (`Expression2`, `Essence2Kit`, `Essence2`, legacy `bitHumanKit`) keep
`https://github.com/bithuman-product/homebrew-bithuman.git`: every released 2.x tag stays there.
2.x takes critical fixes only, tagged in https://gitlab.com/bithuman/sdk/bithuman-swift (which carries
every 2.x tag): an app that needs one switches its package URL there and keeps its version requirement.

## Rules

- **Plan.** From 12 October 2026, API and SDK use requires the Creator plan or higher. Never tell a user they can build on a free plan.
- **Billing.** Sessions bill active session time, talking or idle, to the second. Quote rates only from `/v1/pricing` or the docs pricing page.
- **The API secret.** One credential for every surface, `BITHUMAN_API_SECRET`. Keep it in the environment or the Keychain, never in source, argv or a build flag. An app you distribute holds the secret on every device, so fetch it from your backend at startup, use a separate secret per app, and rotate it if usage looks wrong. In a LiveKit worker, name it `BITHUMAN_MASTER_SECRET` and pass a minted token (https://docs.bithuman.ai/platforms/livekit).
- **Where things happen.** Say where the avatar renders (device, browser, your server, or the bitHuman cloud) and where the conversation runs (your stack, the CLI's local conversation brain, or bitHuman's servers). Phones, Macs and browsers stay online: a session checks the credential when it starts.
- **Versions.** Never write a version from memory; read `versions.json`, the tap's tags (`git ls-remote --tags`), PyPI or maven.bithuman.ai (`ai.bithuman/<artifact>/maven-metadata.xml`).
- **The CLI is not on PyPI.** `pip install bithuman` is the Python library and puts no `bithuman` command on PATH. Install the CLI with `brew tap bithuman/bithuman https://gitlab.com/bithuman/sdk/homebrew-bithuman && brew install bithuman-cli` (macOS) or `curl -fsSL https://install.bithuman.ai | sh` (macOS, Linux).

## Working in this repository

- `Package.swift` (Swift 2.x, critical fixes only) is resolved by bare `v*` tags. Its binary targets, URLs and checksums change only in a release; `scripts/check-manifest-truth.py` checks them against the published bytes. It moves to the Swift project's `release/2.x` branch.
- The tap must always be tapped with its URL: `scripts/check-explicit-tap.py` refuses any tap line without the URL, and any shortened install that does not tap the URL first, anywhere in the tree.
- Release tags and what each one ships: [RELEASE.md](RELEASE.md).
- `scripts/guard-public-vocabulary.py` keeps internal vocabulary out of this public repository; run it before you push.
