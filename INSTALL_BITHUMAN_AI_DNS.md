# Setting up `install.bithuman.ai` (one-time DNS setup)

## ★THE WORKER (2026-10): it PROXIES this repository's GitLab `main`, and `/windows` serves install.ps1

What runs is the Cloudflare Worker `bithuman-install` (account-level script, routed on
`install.bithuman.ai/*`). It does not redirect: it fetches the installer from this repository's
`main` on GitLab (`https://gitlab.com/bithuman/sdk/homebrew-bithuman/-/raw/main/`) and serves it
with `x-bithuman-upstream` naming the file. Every path serves `install.sh`, except `/windows` (and
`/windows.ps1`, `/install.ps1`), which serves `install.ps1` as text/plain for
`irm https://install.bithuman.ai/windows | iex`.

**The source is [`workers/install-bithuman-ai.mjs`](workers/install-bithuman-ai.mjs)**, deployed
verbatim. Until the 2026-10 move to GitLab the same Worker read
`https://raw.githubusercontent.com/bithuman-product/homebrew-bithuman/main/`; the upstream (`TAP`)
is the only line that changed. The installers it serves read releases from
`https://downloads.bithuman.ai/homebrew-bithuman` (`latest.json`, `releases.json`,
`<tag>/<asset>`) and make no GitHub request.

Deploy with the Workers API (`PUT /accounts/<acc>/workers/scripts/bithuman-install`,
module `index.js` = the file above, compatibility_date `2026-09-01`, no bindings), then verify both
routes: `curl -sI https://install.bithuman.ai` names `.../-/raw/main/install.sh` in
`x-bithuman-upstream`, and `curl -sI https://install.bithuman.ai/windows` names `install.ps1`.
Roll back by re-deploying the previous script version (Workers keeps versions), whose `TAP` is the
GitHub raw URL above; the GitHub copy keeps serving its frozen installers (also once it is archived).

### History (before October 2026)

Until the move the Worker's upstream was this repository's `main` on GitHub
(`raw.githubusercontent.com`); that is now only the Worker rollback target, and the GitHub copy
keeps serving its frozen installers there (also once it is archived). The original 2026-09 setup options (a Worker with a
GitHub raw upstream, or a Cloudflare Page Rule redirecting to it) are superseded by the Worker
source above and are no longer documented here; they are in this file's git history.

---

## Why proxy (and not host the script on Cloudflare directly)

The canonical script lives in this tap repo's `main` branch — every push
updates it instantly. A redirect keeps the installer single-sourced and
auditable in git; Cloudflare just shortens the URL.

### ★The release-asset URL never worked (history, kept as a warning)

Until 2026-09-13 this section offered a fallback on the GitHub releases of the time:

    https://github.com/bithuman-product/homebrew-bithuman/releases/latest/download/install.sh

MEASURED 2026-09-13, it is a **404**, and for two independent reasons:

1. **`/releases/latest` is not the CLI.** GitHub resolves it to whichever
   non-draft, non-pre-release release was published most recently across the
   WHOLE repository, and this tap publishes several families from one
   repository — `cli-v*` (the CLI), bare `v*` (the Swift SDK),
   `essence2-v*` (the Apple engine), `cli-engine-essence2-w2v-*` (engine
   assets), `*-mac` (the Sparkle feed). Today it resolves to
   `cli-engine-essence2-w2v-v2`, an engine-asset release, and the URL above
   redirects to `.../releases/download/cli-engine-essence2-w2v-v2/install.sh`.
   That is exactly the taxonomy problem `install.sh` itself documents and
   solves by picking the newest `cli-v*` rather than trusting "latest".

2. **No release carries `install.sh` at all.** The claim that "the publish
   workflow attaches it on every tag" is not true of any release in this tap.
   `cli-v2.6.9` carries four assets and none of them is the installer:

       bithuman-aarch64-apple-darwin.tar.gz{,.sha256}
       bithuman-x86_64-unknown-linux-gnu.tar.gz{,.sha256}

So there is ONE installer URL, `main`'s raw `install.sh` (served through the Worker above), and
proxying it is the only shortening that can be correct. Do not re-add an
asset-URL fallback without first attaching `install.sh` to the CLI release AND
pinning the tag — a fallback that 404s is worse than no fallback, because it
is reached exactly when the primary is already failing.
