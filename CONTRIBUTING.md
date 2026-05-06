# Contributing

This repo is the **Homebrew tap** for `bithuman-cli`. It hosts the formula and the notarized release artifacts; that's it. The CLI source itself lives in a private repo, and the formula is bumped automatically when we cut a new release.

A short orientation:

## What this repo contains

- `Formula/bithuman-cli.rb` — the Homebrew formula. **Bumped automatically on release.** Please don't open PRs that hand-edit version, URL, or sha256.
- `appcast.xml` — Sparkle-style update feed for the GUI Halo app (separate product, but published from this tap).
- `llms.txt` — structured manifest for AI coding assistants installing the CLI.
- `README.md` — the tap's landing page and CLI usage docs.

## Where to send what

### Don't file CLI bug reports here

The CLI source is private and the engineers who can fix bugs don't watch this repo. If `bithuman-cli` crashes, hangs, mis-transcribes, picks the wrong voice, or otherwise misbehaves at runtime, please email **support@bithuman.ai** (or post in the [community forum](https://www.bithuman.ai/community)) so the report routes to the right team.

### Do file an issue here when…

- `brew install bithuman-cli` itself is broken (download fails, sha256 mismatch, dependency conflict, install script error).
- `brew upgrade bithuman-cli` doesn't pick up a release that's been out for a while.
- The formula's caveats or post-install message is wrong / out of date.
- `appcast.xml` serves a stale or invalid update.
- `llms.txt` or this repo's `README.md` is wrong or unclear.
- You hit a real Homebrew tap convention issue (e.g. our formula doesn't lint with `brew audit`).

Use [Bug report](.github/ISSUE_TEMPLATE/bug_report.md) and include `brew config` output and the exact command that failed.

### PRs we welcome

- README fixes and clarifications.
- `llms.txt` improvements.
- Tap-level documentation (an `appcast` README, a doc on how to roll a release locally, etc.).
- Fixes to caveats / post-install messages in the formula (we'll merge those even if release automation would otherwise overwrite — just keep the diff minimal).

### PRs we'll usually close

- Hand-edited version / URL / sha256 bumps in `Formula/bithuman-cli.rb`. These come from release automation. If a release is missing, open an issue instead.
- New formulas for unrelated tools — this tap is single-purpose.

## Local sanity checks before opening a PR

```sh
brew tap bithuman-product/bithuman ./
brew audit --strict bithuman-product/bithuman/bithuman-cli
brew install --build-from-source bithuman-product/bithuman/bithuman-cli  # for local formula edits
```

`brew audit` should be clean (or fail in a way that's clearly preexisting). `brew install` should complete without warnings on a fresh machine.

## Code of conduct

Be kind. Assume good intent.
