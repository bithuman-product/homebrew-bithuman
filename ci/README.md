# Local CI (GitHub Actions is off)

**Owner directive, 2026-09-29:** "disable Actions altogether as github is charging way
too much" · "please also remove all github actions" · "instead we should run local tests
for validation". Actions is disabled for this repo and no status check is required on
`main`. Validation now runs on a developer or release host with `ci/run-local.sh`.

## Run it

```sh
ci/run-local.sh            # the required PR suite (what the PR/push workflows graded)
ci/run-local.sh --list     # every step: default, --full, and manual (host/secret needed)
ci/run-local.sh --only manifest-truth
ci/run-local.sh --full     # adds the slower read-only jobs (release-notes vocabulary)
ci/run-local.sh --no-cap   # skip the systemd-run MemoryMax=8G / CPUQuota=400% / nice 19 wrapper
```

Each step prints one `PASS` / `FAIL` / `SKIP` line; the last line is
`LOCAL CI <PASS|FAIL> sha=<git sha> steps=<n>`. A `SKIP` means the toolchain is missing
on this host (for example `flutter`); run that step on a host that has it before merging
a change it covers. Logs land in `$TMPDIR/local-ci-<repo>-<sha>/`.

Most steps replay a job straight from the old YAML with `ci/wf-step.py <yml> <job>`, so
the recipe and the local run cannot drift: its `run:` steps execute in order, `uses:`
steps are replaced by the local checkout/toolchain, and a step that needs `${{ }}` event
context or a secret is refused rather than faked.

## Evidence convention (required)

Before merging, run `ci/run-local.sh` on the **exact PR head** and post a PR comment with
the command, the sha and the PASS/FAIL lines. **Red = no merge.** A `SKIP` on a step your
change touches needs the same comment from a host where it ran.

## Releases are manual now

Tag pushes no longer publish anything. The release recipes are the disabled workflows;
run their commands by hand on a release host with the named credentials
(`ci/run-local.sh --list`, section "manual"): `release-pypi.yml` (pypi-v*),
`publish-mcp.yml` (mcp-v*), `publish-pubdev.yml` (flutter-v*), `publish-cli-wheel.yml`,
`publish-essence2-apple.yml`. After any release, run
`python3 tools/verify_latest_badge.py --heal` and `ci/run-local.sh --only release-coverage`
(these used to run on `release:` events and a schedule).

## Where the old workflows live

`ci/github-workflows-disabled/*.yml` — kept verbatim as the recipe. They do not run:
GitHub only executes files under `.github/workflows/`.

## Known reds

None on `main` at the time of the switch. `flutter-plugin-tests` SKIPs on hosts without
Flutter; `dev-levers-release-arm`, `voice-render-edge` and `swift-package` need macOS.
