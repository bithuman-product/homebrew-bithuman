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

## macOS code signing (CLI)

`release-cli.yml`'s `mac-tarball` job Developer ID signs every Mach-O it ships
(`scripts/sign-macos.sh`), notarizes them with Apple (`scripts/notarize-macos.sh`),
and then verifies the finished tarball **with the quarantine attribute set**
(`scripts/verify-macos-release.sh`) — the only state that actually exercises
Gatekeeper. Without the signing secrets the job **refuses to publish**; re-dispatch
with `allow_unsigned=true` to override deliberately.

Every release up to and including `cli-v2.4.2` is ad-hoc signed and Gatekeeper
rejects it. `brew install` users are unaffected (Homebrew's `curl` fetch sets no
quarantine attribute); a browser download of the tarball is quarantined, macOS
propagates that onto the extracted files, and the binary is SIGKILLed on launch.

★ **Stapling is not possible for this artifact.** `xcrun stapler` only attaches a
ticket to a disk image, installer package, or bundle — never to a bare Mach-O
executable, which is what the tarball ships. The notarization ticket is therefore
resolved online by CDHash on first launch. Shipping a stapled artifact would mean
publishing a `.dmg`/`.pkg` instead of a `.tar.gz`, which is a distribution change,
not a signing one.

## CLI platform coverage (a partial release must go RED)

`install.sh` resolves the **newest `cli-v*` tag** and downloads
`bithuman-<target>.tar.gz` from it. So a release that carries some platforms and
not others is not a partial success — it is a **total outage for the missing
platform**, and it looks green from the release job.

That shipped on 2026-09-02: `cli-v2.5.0` was cut macOS-only (the `linux-tarball`
job had just been gated behind `build_linux`, correctly, to stop it clobbering
published assets), and every Linux customer running the documented one-liner got

```
curl: (22) The requested URL returned error: 404
install: error: The tarball for x86_64-unknown-linux-gnu may not be published for cli-v2.5.0.
```

with `rc=1`. `cli-v2.4.2` was the accidental fallback.

`tools/verify_release_platform_coverage.py` closes it, mirroring
bithuman-models' `tools/verify_pypi_platform_coverage.py`: it reads the live
Releases index and **refuses if a release carries fewer (asset-kind, target)
pairs than the CLI release before it**. Adding a platform, or adding a missing
`.sha256` sidecar, can only add pairs — an improvement never refuses. Losing a
sidecar does, because `install.sh` silently downgrades to "verification skipped"
rather than failing.

* `verify-release-coverage` in `release-cli.yml` runs it with
  `needs: [mac-tarball, linux-tarball]` and `if: ${{ !cancelled() }}` — a
  SKIPPED build job is exactly the condition it exists to catch.
* Run it by hand any time: `python3 tools/verify_release_platform_coverage.py --tag cli-vX.Y.Z`
  (`rc` 0 green / 1 refusal / 2 index unreadable — unreachable is never green).
* `--self-test` runs the refusal arms **in-process** (never re-execs itself) and
  is a required step in the job, so a green from the gate is only trusted after
  the gate has been shown to fire.
* It compares against the PREDECESSOR, not an ideal, so it cannot see a platform
  neither release ever had — which is why the predecessor's target set is always
  printed, and why `--require <triples>` exists to pin a floor.

★ **Known standing gaps it will not flag** (both releases lack them, so there is
no loss to detect): `install.sh` will ask for `x86_64-apple-darwin` (Intel Mac)
and `aarch64-unknown-linux-gnu` (ARM Linux); no `cli-v*` release has ever
carried either. Linux ARM was last published at `cli-v2.3.27`.

## Secrets (this repo, or org-level — all repos inherit)
`PYPI_API_TOKEN`, `PYPI_USERNAME` (=`__token__`), `BITHUMAN_MODELS_SSH_KEY` (private half of the read-only deploy key `homebrew-bithuman-ci-ro` on the `bithuman-models` engine monorepo — probe it with the `preflight` workflow). No Maven/Android/OSSRH/GPG.

## Cut a release
- **PyPI wheel** — tag `bithuman-models` `essence1-v<x.y.z>` (must match `models/essence-1/sdk/python/pyproject.toml`), then `git tag pypi-v<x.y.z> && git push --tags` here. Dry run: run `release-pypi.yml` via *workflow_dispatch* with `publish=false` (builds the 9-wheel matrix, publishes nothing).
- **MCP** — bump `packages/python-mcp/pyproject.toml`, `git tag mcp-v<x.y.z>`.
- **Flutter plugin** — enable *Automated Publishing* on `pub.dev/packages/bithuman/admin` once, bump `packages/flutter-plugin/pubspec.yaml`, `git tag flutter-v<x.y.z>`.
- **CLI** — build in `bithuman-cli`, publish the tarballs as a **`cli-v<x.y.z>`** Release here, bump `Formula/bithuman-cli.rb` (`url`/`version`/`sha256`).
- **Swift SDK** — cut a bare `v<x.y.z>` **above** the highest existing bare tag (`v2.3.25`), **tag-only** (no Release object so `install.sh` ignores it), with `Package.swift`'s `binaryTarget` URL+checksum pointing at a hosted xcframework. Consumers pin `.package(url: …/homebrew-bithuman, from: "<x.y.z>")`.

> PyPI is **yank-only**, pub.dev is **retract-only** — publishes are permanent. Tag deliberately; dry-run first.
