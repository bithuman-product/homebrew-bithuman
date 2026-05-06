# Security Policy

This repo is the Homebrew tap for `bithuman-cli`. The CLI binary is built from a private source repo and notarized by Apple before being attached to a GitHub Release. This tap just publishes the formula that points at those artifacts.

## Reporting a vulnerability

**Please don't file a public GitHub issue.** Email **security@bithuman.ai** with:

- A description of the issue and what an attacker could do.
- Reproduction steps. For tap / installation issues, include `brew config` output and the exact command that triggered it. For runtime CLI issues, include the `bithuman-cli --version` output and OS / hardware.
- The release tag or commit where you observed the problem.
- Your name or handle if you'd like public credit in the advisory.

## In scope for this repo

- Tampering or supply-chain concerns with the published formula, release artifacts, or `appcast.xml`.
- A formula post-install or caveats message that could trick users into running unsafe commands.
- Issues with the way `bithuman-cli` is signed or notarized in releases attached here.

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
