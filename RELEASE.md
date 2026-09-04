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

## ★STANDING RED — `release-cli` cannot cut a Linux tarball (opened 2026-09-02)

`release-cli` has run 7 times and succeeded once (2026-08-02). Both dispatches on
2026-09-02 failed at the same place, and it is **not a CI defect** — it is a
published-artifact defect that the gate is correctly refusing to ship past.

| | |
|---|---|
| **What is red** | `release-cli` → `linux-tarball` → *"Build + vendor + gate the linux tarball"*, gate 2 (host↔engine) |
| **Runs** | 33602563547, 33603750648 (both `workflow_dispatch`, 2026-09-02) |
| **Verdict** | `host-engine gate: host exited before READY (rc=3)` |
| **Root cause** | The published showcase avatar **`wise-pup.imx`** carries `identity.tflite` (the two-artifact split's DELTA half), declares no `expr2-shared-enc` base in `dependencies[]`, and carries no `shared-enc.tflite`. Confirmed on the published bytes with `bithuman info --json` (sha256 `d677173de4a4025b…`, 89,354,265 B, 14 members, `dependencies` null). The freshly-built LiteRT host freezes `shared_enc_dep.py` and refuses it at load. |
| **Why it must stay red** | Pairing the wrong shared encoder renders **a different face with no error** — 181 of 181 frames wrong, silently (measured 2026-09-01). Shipping this host would break `bithuman run`, the out-of-box showcase, for every Linux customer. |
| **Owner action** | Re-emit `wise-pup.imx` through `tools/imx_from_bundle.py` so it stamps its base content address, then re-dispatch with `build_linux=true`. This is an **expression-2 artifact publish** — it replaces bytes customers already hold — so it is deliberately not automated. |
| **Owner** | expression-2 artifact publishing (owner action; not a CI lane) |
| **Expiry** | **2026-09-17.** If it is still red then, either the re-emit has stalled or the CLI's Linux lane should stop claiming a vendored engine. Do not extend it silently. |

★ **Do not buy this green.** Widening the gate, skipping gate 2, or pinning the
old host all ship a CLI whose showcase avatar renders the wrong face. The 2.5.0
and 2.5.1 Linux tarballs were cut by vendoring the host `cli-v2.4.2` already
shipped, unchanged — that is the workaround, and it is why those releases exist
at all.

### What this red costs, beyond the workflow

`release-cli` is the **only** path that builds both halves from one `cli_ref` in
one dispatch. While it is unavailable, halves get uploaded by hand — and that is
how `cli-v2.5.1` came to carry two assets built from two different source trees
(see below).

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

★ **Known standing gaps it will not flag** (the release under test and its
predecessor both lack them, so there is no *loss* to detect): `install.sh`
computes `x86_64-apple-darwin` (Intel Mac) and `aarch64-unknown-linux-gnu`
(ARM Linux) as targets.

★ **CORRECTED 2026-09-04, and the correction matters more than the typo.** The
two sentences that used to stand here contradicted each other — *"no `cli-v*`
release has ever carried either"* immediately followed by *"Linux ARM was last
published at `cli-v2.3.27`"*. The second is the true one, measured by fetching
every URL:

| tag | `aarch64-unknown-linux-gnu` | `x86_64-unknown-linux-gnu` | `aarch64-apple-darwin` |
|---|---|---|---|
| `cli-v2.5.1`  | **404** | 200 | 200 |
| `cli-v2.5.0`  | **404** | 200 | 200 |
| `cli-v2.4.2`  | **404** | 200 | 200 |
| `cli-v2.3.27` | **200** (40,082,649 B) | 200 | 200 |

ARM Linux was published through `cli-v2.3.27` and dropped at `cli-v2.4.0`, when
the tarball began vendoring the expression-2 render engine and only an x86_64
Linux engine was built. `x86_64-apple-darwin` really has never shipped.

A false *"never had it"* is worse than a missing check, because it is the
sentence a reader uses to decide the 404 is expected. The coverage tool compares
against the PREDECESSOR only, so a platform dropped five releases ago is
permanently invisible to it — and this paragraph was the thing standing in for
the check it cannot make.

★ **What actually closed the customer-visible half**: `install.sh` no longer
builds a URL for a target the release does not carry. It asks the release for
its asset list first and REFUSES, naming what *is* published and what to do
instead, rather than emitting a 404 dressed as *"download failed … may not be
published"*. `sh install.sh --self-test` proves it discriminates: the same
target is `MISSING` on `cli-v2.5.1` and `OK` on `cli-v2.3.27`.
Restoring the platform is a separate, costed job: it needs an aarch64 Linux
render engine, which does not exist.

## Atomicity: what the gate closes, and what it does NOT (measured 2026-09-03)

`check-release-atomic.sh` runs seven checks. Five of them run in CI:

| | closes |
|---|---|
| C1 COMPLETE | both tarballs + both sidecars present |
| C2 NONEMPTY | each asset above its size floor |
| C3 SIDECAR-SHAPE | each sidecar is `<64 hex>  <its own filename>` |
| C4 FORMULA-PIN | the formula's url/sha256 point at this tag's macOS asset |
| C5 ATOMIC | no asset was created after `published_at` |
| C6 BYTES | recomputed sha256 matches the sidecar — **needs `--verify-bytes --assets DIR`, which `release-atomic` does not pass, so C6 SKIPs on every CI run** |
| C7 ONE BUILD | ★ **added 2026-09-04** — every tarball's *interior* build clock agrees to within 4 h. Same `--verify-bytes --assets DIR` requirement as C6, so it also SKIPs on a manifest-only CI run |

★**No check bound an asset to a source tree until 2026-09-04.** `git grep` over `scripts/`,
`tools/` and `.github/` finds no commit, provenance or build-id comparison
anywhere. So this shape passes all six:

> two tarballs, built from **two different trees**, both printing the same
> `--version`, both matching their own sidecar, both uploaded before publish.

That is not hypothetical — it is `cli-v2.5.1`, minus the timing:

* tag published `2026-09-02T12:44:19Z`
* macOS asset created `12:43:36Z` — newest CLI commit then was `38e75ba`
* Linux asset created `19:42:49Z` — **44 seconds** after CLI commit `2f210b3`,
  *"expr2 linux engine: re-pin to the clean-room rebuild"*
* `release-cli` had **zero successful runs** that day (7 total, last success 08-02),
  and no workflow in `bithuman-product/bithuman` uploads a release asset
  (verified by grep) — so **both halves were uploaded by hand, 7 h apart**

★ **CORRECTED 2026-09-04 — "two different trees" IS NOT WHAT THE ARTIFACTS SAY,
and the difference matters.** The bullets above read the UPLOAD clock. Reading the
BUILD clock inside each tarball, and lining it up against the CLI repo's commit
graph, gives a sharper and less alarming picture:

```
38e75ba committed            2026-09-02 12:41:34Z
  mac  ./bithuman built      2026-09-02 12:42:02Z   <- 28 s after that commit
  mac  asset uploaded        2026-09-02 12:43:36Z
  linux bithuman built       2026-09-02 19:32:58Z   <- 6 h 51 m later
2f210b3 committed            2026-09-02 19:42:05Z   <- 9 min AFTER the linux BUILD
  linux asset uploaded       2026-09-02 19:42:49Z   <- 44 s after that commit
```

★ **There are ZERO CLI commits, on ANY ref, between 12:41:34Z and 19:42:05Z**
(`git log --all --since --until`, count 0). So the two halves were almost certainly
built from the SAME commit, `38e75ba` — the `44 seconds after 2f210b3` above is the
UPLOAD, and `2f210b3` landed *after* the Linux build, recording the engine re-pin
that build had already used rather than being the tree it came from.

What is established is **two BUILDS, 6 h 51 m apart, one release** — which is what
`C7 ONE BUILD` refuses, and it is enough: the two halves were assembled by hand, in
two sittings, with a live tree between them, and the only reason they agree is that
nobody happened to commit. What is NOT established from the artifacts is two
different CLI source trees. Saying the stronger thing was not measured.

C5 catches that pair *today* only because the Linux half landed after publish.
Upload both before flipping the draft and the same two-tree release goes green.

The sidecar cannot help: it is generated from the tarball at upload time, so it
agrees with whatever bytes were just built. **A sidecar can never disagree with
the artifact it was cut from** — it proves transport, not identity.

★ **THE GAP IS CLOSED, and without the CLI build change this section asked for.**
The paragraph here used to say the fix "needs a stamp in the tarball, which is a
CLI build change, not a tap change". It does not. **The build clock is already in
the archive** — the mtimes the build machine stamped on every member — and
`C7 ONE BUILD` reads it. That matters for three reasons: it needs no cooperation
from the CLI repo, it works **retroactively on every release already published**,
and unlike C5 it survives a tidy re-upload, because it grades when the bytes were
*made*, not when they were *pushed*.

Measured on the real `cli-v2.5.1` assets, 2026-09-04 (`--verify-bytes --assets`):

```
[C5] FAIL  … uploaded 6h58m after publish
[C6] PASS  recomputed sha256 matches the sidecar for 2 tarball(s)
[C7] FAIL  the assets are from DIFFERENT BUILDS:
           bithuman-aarch64-apple-darwin.tar.gz     built 2026-09-02T12:42:02Z
           bithuman-x86_64-unknown-linux-gnu.tar.gz built 2026-09-02T19:32:58Z
           — 6.85 h apart, window is 4 h.
```

C6 PASSES beside it: **both halves match their own sidecars perfectly and the
release is still two builds** — which is the whole point, and the reason a
checksum was never going to catch this. The interior clocks also sit 1.5 min and
10 min *before* the upload times recorded above, exactly as build-then-upload
predicts, so the two instruments corroborate rather than repeat each other.

The positive control is a real release, not a fixture: `cli-v2.3.27`'s three
tarballs were built 16:10, 16:23 and 17:05 — **0.22 h apart, C7 PASS**. So C7
discriminates instead of reddening everything. `--self-test` carries both arms
too (12 min apart green, the 6h58m gap red on C7 and only C7).

**What C7 still cannot see**: two builds of the same commit made minutes apart,
and two builds made in one window from two different trees. A commit stamp in
the tarball would close those, and it is still worth doing. Until then, one
dispatch of `release-cli` with both `build_mac` and `build_linux` ON remains the
only thing that makes the two halves *share* a tree — it takes `cli_ref` once and
both jobs check out that same ref.

## SwiftPM: three artifacts, two vintages, and why no new tag was cut (2026-09-04)

`Package.swift` declares three `binaryTarget`s and pins a sha256 for each.
**All three checksums are correct** — `check-manifest-truth.py` R1 verifies exactly
that and is green. Which is the problem: a checksum binds bytes to a pin and says
nothing about *when*, or from what, those bytes were made.

`tools/spm_artifact_vintages.py` reads the clock stored inside each zip's central
directory — the build machine's mtimes, which travel with the archive and survive
re-uploading, re-tagging and renaming. Measured 2026-09-04:

```
bitHumanKit                  105 entries   built 2026-04-28 13:42:16 .. 13:49:18   checksum MATCHES
Expression2                   38 entries   built 2026-08-29 08:47:18               checksum MATCHES
BithumanEngineProtocolBinary  38 entries   built 2026-08-29 08:47:18               checksum MATCHES

★ 3 artifacts, 2 VINTAGES, 123 days apart
```

★ **Two vintages, not three.** The two August artifacts agree **to the second** —
they really are one build. It is `bitHumanKit` that is old, and **older than its
own release**: it was uploaded to `v2.4.0` on 2026-06-30 but *built* on
2026-04-28. An upload date understates the gap by two months; the interior clock
does not.

★ **This is REPORTED, not refused, and that is deliberate.** The split base
constants are a *fix*, and `Package.swift` carries its own measurement for them:
`releaseBase` is shared by every binaryTarget, so bumping `releaseTag` v2.4.0 →
v2.5.0 re-points `bitHumanKit.xcframework.zip` at a tag that does not carry it —
**both URLs HTTP 404**, measured. `expression2Base` is what keeps the shipping
product resolvable. A permanent red for the consequence of a correct fix teaches
people to ignore the gate; what is not acceptable is that nobody could *see* the
spread, and that is what this closes. `--self-test` has four arms including a
same-clock control and the manifest parser.

★ **NO NEW SWIFTPM TAG WAS CUT, and the reason is the standing rule: one build,
one commit, or refuse.** Making the tag atomic requires one release carrying all
three zips built from one commit, with every `binaryTarget` on that one tag. That
needs an **Apple** build of `bitHumanKit`, which cannot be produced on the Linux
host this work was done from — and re-uploading the April bytes under a new tag
would change the tag, not the vintage. Refusing is the correct outcome here;
"authorized" is not "obliged".

## Secrets (this repo, or org-level — all repos inherit)
`PYPI_API_TOKEN`, `PYPI_USERNAME` (=`__token__`), `BITHUMAN_MODELS_SSH_KEY` (private half of the read-only deploy key `homebrew-bithuman-ci-ro` on the `bithuman-models` engine monorepo — probe it with the `preflight` workflow). No Maven/Android/OSSRH/GPG.

## Cut a release
- **PyPI wheel** — tag `bithuman-models` `essence1-v<x.y.z>` (must match `models/essence-1/sdk/python/pyproject.toml`), then `git tag pypi-v<x.y.z> && git push --tags` here. Dry run: run `release-pypi.yml` via *workflow_dispatch* with `publish=false` (builds the 9-wheel matrix, publishes nothing).
- **MCP** — bump `packages/python-mcp/pyproject.toml`, `git tag mcp-v<x.y.z>`.
- **Flutter plugin** — enable *Automated Publishing* on `pub.dev/packages/bithuman/admin` once, bump `packages/flutter-plugin/pubspec.yaml`, `git tag flutter-v<x.y.z>`.
- **CLI** — build in `bithuman-cli`, publish the tarballs as a **`cli-v<x.y.z>`** Release here, bump `Formula/bithuman-cli.rb` (`url`/`version`/`sha256`).
- **Swift SDK** — cut a bare `v<x.y.z>` **above** the highest existing bare tag (`v2.3.25`), **tag-only** (no Release object so `install.sh` ignores it), with `Package.swift`'s `binaryTarget` URL+checksum pointing at a hosted xcframework. Consumers pin `.package(url: …/homebrew-bithuman, from: "<x.y.z>")`.

> PyPI is **yank-only**, pub.dev is **retract-only** — publishes are permanent. Tag deliberately; dry-run first.
