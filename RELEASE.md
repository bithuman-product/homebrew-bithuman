# Releasing

One repo, **one tag prefix per artifact**. Cut a tag, CI does the rest. Don't mix the namespaces.

| Artifact | Tag | Ships to | Driven by |
|---|---|---|---|
| **CLI** (`bithuman`) | `cli-v<x.y.z>` | Homebrew tap + `curl\|bash` | a GitHub Release with the Rust tarballs here; bump `Formula/bithuman-cli.rb` |
| **Python SDK** (`bithuman`) | `pypi-v<x.y.z>` | PyPI | `.github/workflows/release-pypi.yml` |
| **MCP** (`bithuman-mcp`) | `mcp-v<x.y.z>` | PyPI | `.github/workflows/publish-mcp.yml` |
| **Flutter plugin** (`bithuman`) | `flutter-v<x.y.z>` | pub.dev | `.github/workflows/publish-pubdev.yml` |
| **Swift SDK** (`bitHumanKit`) | bare `v<x.y.z>` (tag-only, **no** Release object) | SwiftPM | `Package.swift` (resolved by tag) |
| **Mac app** (Sparkle) | `*-mac` | `appcast.xml` | — |

**Why the prefixes:** SwiftPM resolves packages by **bare semver tags**, so the bare `v*` namespace is the **Swift SDK's alone**. The CLI moved to `cli-v*` to stop colliding (old bare CLI tags ≤ `v2.3.25` are frozen history). `install.sh` and the formula follow `cli-v*` (with a fallback to the old bare tags until the next CLI release).

## Secrets (this repo, or org-level — all repos inherit)
`PYPI_API_TOKEN`, `PYPI_USERNAME` (=`__token__`), `SDK_RO_PAT` (read-only `Contents` on `essence-1`). No Maven/Android/OSSRH/GPG.

## Cut a release
- **PyPI wheel** — tag `essence-1` `v<x.y.z>` (must match `sdk/python/pyproject.toml`), then `git tag pypi-v<x.y.z> && git push --tags` here. Dry run: run `release-pypi.yml` via *workflow_dispatch* with `publish=false` (builds the 9-wheel matrix, publishes nothing).
- **MCP** — bump `packages/python-mcp/pyproject.toml`, `git tag mcp-v<x.y.z>`.
- **Flutter plugin** — enable *Automated Publishing* on `pub.dev/packages/bithuman/admin` once, bump `packages/flutter-plugin/pubspec.yaml`, `git tag flutter-v<x.y.z>`.
- **CLI** — build in `bithuman-cli`, publish the tarballs as a **`cli-v<x.y.z>`** Release here, bump `Formula/bithuman-cli.rb` (`url`/`version`/`sha256`).
- **Swift SDK** — cut a bare `v<x.y.z>` **above** the highest existing bare tag (`v2.3.25`), **tag-only** (no Release object so `install.sh` ignores it), with `Package.swift`'s `binaryTarget` URL+checksum pointing at a hosted xcframework. Consumers pin `.package(url: …/homebrew-bithuman, from: "<x.y.z>")`.

> PyPI is **yank-only**, pub.dev is **retract-only** — publishes are permanent. Tag deliberately; dry-run first.
