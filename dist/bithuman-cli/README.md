# Staged `bithuman-cli` wheels

The wheel(s) here are **release artifacts staged for upload**, not source.
They are the exact bytes that were built and proved on an Apple Silicon host
before publication — `publish-cli-wheel.yml` verifies each one's sha256
against its pin and then `twine upload`s that same file, so what PyPI serves
is byte-for-byte what was tested, not a re-build that merely ought to match.

A wheel stays here after it is uploaded. It is the byte record of what PyPI
serves for that coordinate, and it is what the workflow's pinned sha256
refers to — deleting it would leave the pin describing nothing. Drop one only
when a later coordinate supersedes it and that later one has verified.

(Versions on PyPI are immutable, and deleting a file there permanently
reserves its filename and cannot be undone — yank, never delete. That rule is
why this directory exists at all.)

## 2.3.27 — why it exists

Every `bithuman-cli` file was *deleted* from PyPI on 2026-09-11 rather than
yanked, so the JSON API 404'd and the simple index rendered with zero links.
`bithuman serve`'s first run on Apple Silicon creates a brain venv and runs
`pip install bithuman-cli` (crates/bithuman-cli/src/embedded_agent_worker.rs,
`bootstrap_brain_venv`); that step began failing and left a partial venv
behind. 2.3.0 and 2.3.25 can never be restored — a deleted filename stays
reserved — so the repair had to be a new coordinate. 2.3.27 is it.
