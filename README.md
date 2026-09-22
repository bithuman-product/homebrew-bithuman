<!--
SPDX-License-Identifier: Apache-2.0
title: bithuman CLI — live, talking avatars from your terminal
maintainer: bitHuman Inc.
homepage: https://www.bithuman.ai
project_type: cli
platform: macOS 14+ (Apple Silicon) via Homebrew; Linux x86_64 via install.sh
keywords: avatar, lip-sync, livekit, voice-agent, cli, mcp, realtime
-->

<p align="center">
  <a href="https://www.bithuman.ai">
    <img alt="bitHuman" src="https://docs.bithuman.ai/og-image.jpg" width="220">
  </a>
</p>

<h1 align="center">bithuman</h1>

<p align="center">
  <strong>One command, a live talking avatar in your browser.</strong><br>
  Made by <a href="https://www.bithuman.ai">bitHuman</a>.
</p>

<p align="center">
  <a href="#install"><img alt="brew install" src="https://img.shields.io/badge/brew-install%20bithuman--cli-orange?style=flat-square"></a>
  <a href="#install"><img alt="macOS + Linux" src="https://img.shields.io/badge/macOS%20arm64%20%7C%20Linux%20x86__64-blue?style=flat-square"></a>
  <a href="https://docs.bithuman.ai"><img alt="docs" src="https://img.shields.io/badge/docs-bithuman.ai-lightgrey?style=flat-square"></a>
</p>

---

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

## Install

**macOS (Apple Silicon)** — via this tap:

```sh
brew tap bithuman-product/bithuman
brew trust bithuman-product/bithuman   # Homebrew 6+ gates third-party taps; skip on older brew
brew install bithuman-cli              # `brew install bithuman` works as a deprecated alias
bithuman doctor                        # host + auth + cache sanity check
```

**Linux x86_64** — the formula is macOS-only; use the installer or the tarball:

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

## The commands

The surface is deliberately small — one name per task. `bithuman --help` lists
them, and `bithuman <command> --help` carries a copy-pasteable `EXAMPLES:` block.

| command | what it does |
|---|---|
| `run` (alias `chat`) | Live, talking avatar in the browser. Takes a showcase slug, a local `.imx` path, or one of your agent codes. |
| `list` (alias `avatars`) | The showcase catalogue, and with `--mine` the agents on your account. |
| `pull` | Download a model; prints the cached `.imx` path. |
| `open` (alias `info`) | Model metadata. |
| `render` | Offline render to MP4 from an `.imx` + an audio file. Needs `ffmpeg` on PATH (or `$BITHUMAN_FFMPEG`). |
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

## Docs

Full CLI and SDK documentation: **[docs.bithuman.ai](https://docs.bithuman.ai)**.

- [bithuman CLI reference](https://docs.bithuman.ai/cli/overview)
- [Authentication](https://docs.bithuman.ai/getting-started/authentication)
- [Pricing & credits](https://docs.bithuman.ai/getting-started/pricing)

## What this repo is

`bithuman-product/homebrew-bithuman` hosts the **release artefacts** — the
Homebrew formula, the install script, and the notarised per-target binaries
attached to each `cli-v*` release.

The published CLI binary is a proprietary artifact: it statically links the
bitHuman engine and vendors model weights, so the formula declares
`license :cannot_represent` rather than a single SPDX identifier. The files in
*this repository* (formula, scripts, docs) are Apache 2.0 — see
[`LICENSE`](LICENSE).

## About bitHuman

Built and maintained by [**bitHuman**](https://www.bithuman.ai), the team behind
real-time avatar engines.

- 🌐 [www.bithuman.ai](https://www.bithuman.ai)
- 📦 [github.com/bithuman-product](https://github.com/bithuman-product)

---

<p align="center">
  Made with ❤️ by <a href="https://www.bithuman.ai"><strong>bitHuman</strong></a>.
</p>
