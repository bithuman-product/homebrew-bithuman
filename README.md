<!--
SPDX-License-Identifier: Apache-2.0
title: bitHuman Apple SDK (Swift Package Manager) and the bithuman CLI
maintainer: bitHuman Inc.
homepage: https://www.bithuman.ai
project_type: swift-package, cli
platform: iOS, iPadOS and macOS on Apple silicon (Swift package); macOS (Apple silicon) and Linux x86_64 / arm64 (CLI)
keywords: avatar, talking-avatar, lip-sync, digital-human, swift, swiftpm, ios, macos, cli, mcp
-->

<p align="center">
  <a href="https://www.bithuman.ai">
    <img alt="bitHuman" src="https://docs.bithuman.ai/og-image.jpg" width="220">
  </a>
</p>

<h1 align="center">bitHuman: Apple SDK and CLI</h1>

<p align="center">
  <strong>The Swift package for iPhone, iPad and Mac apps, and the Homebrew tap for the <code>bithuman</code> CLI.</strong><br>
  Made by <a href="https://www.bithuman.ai">bitHuman</a>.
</p>

---

## Apple SDK (Swift Package Manager)

Real-time, lip-synced avatars rendered on iPhone, iPad and Mac: Essence 2 (a photoreal person) and
Expression 2 (any character). Pass in 16 kHz speech from any voice stack; draw the frames.

```swift
.package(url: "https://github.com/bithuman-product/homebrew-bithuman.git", from: "2.19.4")
```

The Swift package lives in this repository, which is also our Homebrew tap, so Xcode and
SwiftPM show its identity as `homebrew-bithuman`. That name is expected; in `Package.swift`
dependencies write `.product(name: "Expression2", package: "homebrew-bithuman")` (or
`Essence2Kit`).

Resolving the package downloads all of its binary frameworks, about 125 MB today (the
legacy `bitHumanKit` is 56 MB of that), even for an app that imports only `Expression2`.
The first resolve on a slow network takes a while; later builds use SwiftPM's cache.

The current version of every package is on [docs.bithuman.ai/versions.json](https://docs.bithuman.ai/versions.json).

| Product | Import | What it is | Deployment target |
|---|---|---|---|
| `Expression2` | `import Expression2` | the Expression 2 engine with a Swift API | iOS 16 · macOS 13 |
| `Essence2Kit` | `import Essence2Kit` | the Essence 2 engine with a Swift API; it includes `Essence2` | iOS 26 · macOS 26 |
| `Essence2` | `import Essence2` | the Essence 2 engine as a C library, for C, C++ and plugins | iOS 26 · macOS 26 |

`bitHumanKit` 2.4.0 is legacy and frozen; new apps use `Expression2` or `Essence2Kit`.

Requires the Creator plan or higher from 12 October 2026. Each session needs an [API secret](https://docs.bithuman.ai/start/api-secret) and bills active session time ([pricing](https://docs.bithuman.ai/pricing)).

Docs: [iOS & iPadOS](https://docs.bithuman.ai/platforms/ios) · [macOS](https://docs.bithuman.ai/platforms/macos) · [Swift reference](https://docs.bithuman.ai/platforms/swift/reference) · Examples: [bithuman-examples/swift](https://github.com/bithuman-product/bithuman-examples/tree/main/swift)

## Homebrew CLI

`bithuman` runs a live, talking avatar in your browser with one command.

### What it does

`bithuman run <avatar>` stands up the whole stack — an embedded LiveKit server,
the render engine, and a conversation brain — and opens your browser to a live,
talking, lip-synced avatar. You speak, it answers, and you can interrupt it.

The conversation brain comes **with your account**, so there is no separate
OpenAI key to configure. Sessions are billed to your bitHuman credits.

```sh
bithuman login                    # sign in once
bithuman run nova                 # a showcase avatar, downloaded on first use
bithuman run ./my-avatar.imx      # your own model, rendered on this machine
```

### Install

**macOS (Apple Silicon)** — via this tap:

```sh
brew tap bithuman-product/bithuman
brew trust bithuman-product/bithuman   # Homebrew 6+ gates third-party taps; skip on older brew
brew install bithuman-cli              # `brew install bithuman` works as a deprecated alias
bithuman doctor                        # host + auth + cache sanity check
```

**Linux (x86_64, arm64)** — the formula is macOS-only; use the installer or the tarball:

```sh
curl -fsSL https://install.bithuman.ai | sh
```

> The Homebrew package is named `bithuman-cli`; the binary it installs is
> `bithuman`, so you type `bithuman run`. The `-cli` suffix is a package name
> only.
>
> **This CLI is not distributed on PyPI**, and `bithuman-cli` is not a pip
> coordinate for it — that name does not resolve there. (`pip install bithuman`
> is the Python SDK *library*, a different artifact; it puts no `bithuman`
> command on your PATH.)

### The commands

The surface is deliberately small — one name per task. `bithuman --help` lists
them, and `bithuman <command> --help` carries a copy-pasteable `EXAMPLES:` block.

| command | what it does |
|---|---|
| `run` (alias `chat`) | Live, talking avatar in the browser. Takes a showcase slug, a local `.imx` path, or one of your agent codes. |
| `list` (alias `avatars`) | The showcase catalogue, and with `--mine` the agents on your account. |
| `pull` | Download a model; prints the cached `.imx` path. |
| `open` (alias `info`) | Model metadata. |
| `render` | Render an MP4 from an avatar and an audio file. Needs `ffmpeg` on PATH (or `$BITHUMAN_FFMPEG`). |
| `account` | Who the credential belongs to, the plan, the balance, and the spend behind it. |
| `login` / `logout` | Sign in and out. |
| `doctor` | Install health. Exit 0 iff ready. |
| `engine` | Manage the bundled render engine. |
| `mcp` | Built-in MCP server over stdio, for MCP clients. |
| `completion` | Shell completions for bash, zsh, fish, elvish, powershell. |

Every command takes `--json` and follows sysexits exit codes, so it scripts
cleanly. `bithuman __schema` prints the entire command / flag / exit-code tree
plus the MCP tool catalogue as one JSON document — that is the authoritative
description of the surface, generated from the binary itself.

### For agents and LLMs

This repo publishes [`llms.txt`](llms.txt), a structured manifest aimed at AI
coding assistants discovering and invoking bithuman. Agents should start there,
then call `bithuman __schema` for the machine-readable surface.

## Docs

Full CLI and SDK documentation: **[docs.bithuman.ai](https://docs.bithuman.ai)**.

- [bithuman CLI](https://docs.bithuman.ai/platforms/cli) · [CLI reference](https://docs.bithuman.ai/platforms/cli/reference)
- [Your API secret](https://docs.bithuman.ai/start/api-secret)
- [Pricing and credits](https://docs.bithuman.ai/pricing)

## What this repo is

`bithuman-product/homebrew-bithuman` hosts the Swift package (`Package.swift` and the
binary frameworks attached to its releases) and the **CLI release artefacts**: the
Homebrew formula, the install script, and the notarised per-target binaries attached
to each `cli-v*` release.

The published CLI binary is a proprietary artifact: it statically links the
bitHuman engine and vendors model weights, so the formula declares
`license :cannot_represent` rather than a single SPDX identifier. The files in
*this repository* (formula, scripts, docs) are Apache 2.0 — see
[`LICENSE`](LICENSE).

## About bitHuman

Built and maintained by [bitHuman](https://www.bithuman.ai): [www.bithuman.ai](https://www.bithuman.ai) · [github.com/bithuman-product](https://github.com/bithuman-product)
