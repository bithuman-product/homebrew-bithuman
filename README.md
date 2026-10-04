<!--
SPDX-License-Identifier: Apache-2.0
title: bitHuman CLI: Homebrew tap and installers
maintainer: bitHuman Inc.
homepage: https://www.bithuman.ai
project_type: homebrew-tap, cli-installer
platform: macOS (Apple silicon), Linux x86_64 / arm64, Windows x86_64 (CLI)
keywords: avatar, talking-avatar, lip-sync, digital-human, cli, homebrew, installer, mcp
-->

<p align="center">
  <a href="https://www.bithuman.ai">
    <img alt="bitHuman" src="https://docs.bithuman.ai/og-image.jpg" width="220">
  </a>
</p>

<h1 align="center">bitHuman CLI: installers and Homebrew tap</h1>

<p align="center">
  <strong>Install the <code>bithuman</code> CLI with one command: the installer script, or the Homebrew tap.</strong><br>
  Made by <a href="https://www.bithuman.ai">bitHuman</a>.
</p>

<p align="center">
  <a href="https://discord.gg/x3tMhJvX4X"><img alt="Discord" src="https://img.shields.io/badge/Discord-join-5865F2?logo=discord&logoColor=white"></a><br>
  Questions, demos and challenges: <a href="https://discord.gg/x3tMhJvX4X">join the bitHuman Discord</a>.
</p>

---

## Install the CLI

`bithuman` runs a live, talking avatar in your browser with one command.

**macOS (Apple silicon) and Linux (x86_64, arm64)**: the installer script. This is the
recommended install.

```sh
curl -fsSL https://install.bithuman.ai | sh
```

**Windows (x86_64)**, from PowerShell:

```powershell
irm https://install.bithuman.ai/windows | iex
```

**Homebrew (macOS, Apple silicon)**: tap this repository by its URL, then install:

```sh
brew tap bithuman/bithuman https://gitlab.com/bithuman/sdk/homebrew-bithuman
brew install bithuman-cli              # `brew install bithuman` works as a deprecated alias
bithuman doctor                        # host + auth + cache sanity check
```

> **Always tap with the URL, and never shorten the install to
> `brew install bithuman/bithuman/bithuman-cli` on a machine that has not tapped it.** Without the
> URL, Homebrew looks for a tap named `bithuman/bithuman` on GitHub, and `github.com/bithuman` is
> not a bitHuman account. The only bitHuman tap is the one above. Homebrew 6+ may also ask you to
> trust a new third-party tap (`brew trust bithuman/bithuman`).

**No package manager**: every release publishes per-target tarballs at
`https://downloads.bithuman.ai/homebrew-bithuman/<tag>/bithuman-<target>.tar.gz`, each with a
`.sha256` beside it. [`latest.json`](https://downloads.bithuman.ai/homebrew-bithuman/latest.json)
names the newest CLI release and
[`releases.json`](https://downloads.bithuman.ai/homebrew-bithuman/releases.json) lists them all.

> The Homebrew package is named `bithuman-cli`; the binary it installs is
> `bithuman`, so you type `bithuman run`. The `-cli` suffix is a package name
> only.
>
> **This CLI is not distributed on PyPI**, and `bithuman-cli` is not a pip
> coordinate for it — that name does not resolve there. (`pip install bithuman`
> is the Python SDK *library*, a different artifact; it puts no `bithuman`
> command on your PATH.)

## What it does

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

## The commands

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

## For agents and LLMs

This repo publishes [`llms.txt`](llms.txt), a structured manifest aimed at AI
coding assistants discovering and invoking bithuman. Agents should start there,
then call `bithuman __schema` for the machine-readable surface.

## The SDKs live in their own projects

This repository is the CLI's tap and installers only. Each SDK has its own home:

| Platform | Install | Docs |
|---|---|---|
| Swift (iOS, iPadOS, macOS) | `.package(url: "https://gitlab.com/bithuman/sdk/bithuman-swift", from: "3.0.0")` | https://docs.bithuman.ai/platforms/ios |
| Flutter | `bithuman: ^3.0.0` from [pub.dev](https://pub.dev/packages/bithuman) | https://docs.bithuman.ai/platforms/flutter |
| Android | `ai.bithuman:bithuman-android` from https://maven.bithuman.ai | https://docs.bithuman.ai/platforms/android |
| Python | `pip install bithuman` | https://docs.bithuman.ai/platforms/python |

Source code: [Swift](https://gitlab.com/bithuman/sdk/bithuman-swift) · [Flutter](https://gitlab.com/bithuman/sdk/bithuman-flutter) · every public bitHuman project is listed at https://gitlab.com/bithuman.
The current version of every package is on [docs.bithuman.ai/versions.json](https://docs.bithuman.ai/versions.json).
Apps already on Swift 2.x or Flutter 2.6.x keep building unchanged: see "Moving from GitHub" below.

## Docs

Full CLI and SDK documentation: **[docs.bithuman.ai](https://docs.bithuman.ai)**.

- [bithuman CLI](https://docs.bithuman.ai/platforms/cli) · [CLI reference](https://docs.bithuman.ai/platforms/cli/reference)
- [Your API secret](https://docs.bithuman.ai/start/api-secret)
- [Pricing and credits](https://docs.bithuman.ai/pricing)

## Moving from GitHub

This repository moved from `github.com/bithuman-product/homebrew-bithuman` to
**https://gitlab.com/bithuman/sdk/homebrew-bithuman** in October 2026, and new releases are published to **https://downloads.bithuman.ai**.
The GitHub copy stays readable: every version released before the move keeps installing from it,
but new CLI and Swift versions are not published there. It becomes a read-only archive when Flutter
2.6.x maintenance ends (below); archiving changes nothing for the apps and taps that use it.

- **The installers** (`curl -fsSL https://install.bithuman.ai | sh`,
  `irm https://install.bithuman.ai/windows | iex`) need nothing: the same commands now fetch from
  https://downloads.bithuman.ai.
- **Homebrew:** re-tap once to follow new releases (an existing `bithuman-product/bithuman` tap keeps
  working, frozen at the last formula published before the move):
  ```sh
  brew uninstall bithuman-cli
  brew untap bithuman-product/bithuman
  brew tap bithuman/bithuman https://gitlab.com/bithuman/sdk/homebrew-bithuman
  brew install bithuman-cli
  ```
- **Swift 2.x** apps keep `https://github.com/bithuman-product/homebrew-bithuman.git` (every released
  2.x tag stays there). 2.x gets critical fixes only, tagged in
  https://gitlab.com/bithuman/sdk/bithuman-swift, which carries every 2.x tag: the URL changes once, to
  that project, when the app adopts Swift 3.0 or needs a 2.x fix. Do not point SwiftPM at this GitLab
  repository.
- **Flutter 2.6.x** apps keep their git dependency on the GitHub repository (`path:
  packages/flutter-plugin`, `ref: flutter-plugin-v2.6.<n>`). 2.6.x gets critical fixes only: each one
  is tagged `flutter-plugin-v2.6.<n>` both there and in https://gitlab.com/bithuman/sdk/bithuman-flutter,
  so an app bumps only `ref:`. 3.x is `bithuman: ^3.0.0` from pub.dev.

## What this repo is

`bithuman/sdk/homebrew-bithuman` is the Homebrew tap for the `bithuman` CLI (`Formula/`,
`Aliases/`), the installer scripts behind https://install.bithuman.ai (`install.sh`,
`install.ps1`) and their tests, and the release tooling that publishes CLI releases to
https://downloads.bithuman.ai/homebrew-bithuman. (`Package.swift` and `Sources/` remain here only so
already-released 2.x builds keep resolving; they move to the Swift project.)

The published CLI binary is a proprietary artifact: it statically links the
bitHuman engine and vendors model weights, so the formula declares
`license :cannot_represent` rather than a single SPDX identifier. The files in
*this repository* (formula, scripts, docs) are Apache 2.0 — see
[`LICENSE`](LICENSE).

## About bitHuman

Built and maintained by [bitHuman](https://www.bithuman.ai): [www.bithuman.ai](https://www.bithuman.ai) · [gitlab.com/bithuman](https://gitlab.com/bithuman)
