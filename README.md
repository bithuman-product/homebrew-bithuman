# bitHuman Swift package and Homebrew tap

> **This project moved to GitLab: https://gitlab.com/bithuman/sdk/homebrew-bithuman**
> This GitHub copy is archived and no longer updated; its old files may describe requirements that are no longer true.
> bitHuman is actively developed. Issues and merge requests go to GitLab.

Swift package: `.package(url: "https://gitlab.com/bithuman/sdk/homebrew-bithuman", from: "<version from versions.json>")` (https://docs.bithuman.ai/platforms/ios)

CLI: `curl -fsSL https://install.bithuman.ai | sh`, or `brew tap bithuman/bithuman https://gitlab.com/bithuman/sdk/homebrew-bithuman && brew install bithuman/bithuman/bithuman-cli` (https://docs.bithuman.ai/platforms/cli)

## What bitHuman is today

- Real-time talking avatars from one portrait. **Essence 2** renders a photoreal person; **Expression 2** renders any character (people, animals, cartoons).
- Renders on the device: iPhone, iPad and Mac (Swift package), Android arm64 (Android SDK), macOS and Linux (CLI, Python), Windows 11 x86_64 (Python), and in a browser tab with WebGPU. Both models also run live on a standard Linux PC with no GPU. Or use the bitHuman cloud (REST API, web embed, LiveKit).
- Ways to build: Swift package, Android SDK, Python SDK, CLI with a built-in MCP server, LiveKit Agents plugin, Pipecat, Flutter, web embed, REST API.
- API and SDK use requires the Creator plan or higher.
- Current versions: https://docs.bithuman.ai/versions.json · measured speed by device: https://docs.bithuman.ai/performance

## Links

- Docs: https://docs.bithuman.ai (for AI assistants: https://docs.bithuman.ai/llms.txt)
- Source: https://gitlab.com/bithuman
- Website: https://www.bithuman.ai · Discord: https://discord.gg/JtFz5Mra7w
