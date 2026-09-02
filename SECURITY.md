# Security Policy

This repo is the Homebrew tap for `bithuman` (formerly `bithuman-cli`). The CLI binary is built from a private source repo by `.github/workflows/release-cli.yml`, which Developer ID signs it as **bitHuman Inc. (G64NFNZX84)** with the hardened runtime and notarizes it with Apple before attaching it to a GitHub Release. This tap just publishes the formula that points at those artifacts.

> **Releases up to and including `cli-v2.4.2` are AD-HOC signed and Gatekeeper rejects them.** This page previously claimed those builds were notarized; they were not. Measured against the published `cli-v2.4.2` tarball (sha256 `49582d8ced9c78c9…`): `codesign -dv` reports `Signature=adhoc` and `TeamIdentifier=not set`, and `spctl -a -t install` reports `rejected`.
> Installs via `brew install` are unaffected in practice — Homebrew fetches with `curl`, which sets no `com.apple.quarantine` attribute, and Gatekeeper only evaluates quarantined files. If you downloaded the tarball from the Releases page **in a browser**, macOS propagates quarantine onto every extracted file and the binary is killed on launch (SIGKILL, no message). Either re-install with `brew install bithuman-cli`, or clear the attribute yourself with `xattr -dr com.apple.quarantine <dir>` after checking the published sha256.

## Reporting a vulnerability

**Please don't file a public GitHub issue.** Email **hello@bithuman.ai** with:

- A description of the issue and what an attacker could do.
- Reproduction steps. For tap / installation issues, include `brew config` output and the exact command that triggered it. For runtime CLI issues, include the `bithuman --version` output and OS / hardware.
- The release tag or commit where you observed the problem.
- Your name or handle if you'd like public credit in the advisory.

## In scope for this repo

- Tampering or supply-chain concerns with the published formula, release artifacts, or `appcast.xml`.
- A formula post-install or caveats message that could trick users into running unsafe commands.
- Issues with the way `bithuman` is signed or notarized in releases attached here.

## Out of scope (please email support@bithuman.ai instead)

- Runtime vulnerabilities inside the CLI binary itself (we'll route to the SDK security team).
- Issues in Homebrew itself — please report to <https://github.com/Homebrew/brew/security>.
- Findings that require physical access or a compromised macOS install.

## What to expect

- Acknowledgement **within 48 hours**.
- We'll keep you updated as we triage and fix.
- We support **coordinated disclosure** and will agree on a public disclosure date with you.
- A GitHub Security Advisory once the fix has shipped, crediting you unless you'd rather stay anonymous.

Thanks for helping keep bitHuman users safe.
