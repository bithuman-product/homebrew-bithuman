# macOS auto-update (Sparkle) — runbook

The direct-download macOS app (`.dmg`, distributed outside the App Store) updates
itself in place with [Sparkle](https://sparkle-project.org). The App Store / iOS
build does **not** use this — Apple ships those updates.

## How it works (and why it keeps working forever)

Every install permanently carries two facts, baked into `Info.plist`:

| key | value | meaning |
|---|---|---|
| `SUFeedURL` | `https://updates.bithuman.ai/appcast.xml` | where it polls for updates (daily) |
| `SUPublicEDKey` | `k7kojeUZvXJ2i3Gb6/JJbaPKnPQnDqK6fCOI03I+z3o=` | the only key whose signatures it will trust |

These two values **never change**. So an update is just: publish a newer build,
EdDSA-signed by the matching **private key**, to that URL. Every install picks it
up, verifies the signature against the frozen public key, and installs it.

Two things must therefore stay true for updates to keep working:

1. **The EdDSA private key must never be lost.** Its public half is frozen in
   every copy ever shipped. Lose the private key → you can never sign another
   update → auto-update is dead for all existing users, permanently, with no
   recovery (you'd have to get every user to manually download a rebuilt app
   with a new key). **ESCROW IT** — see below.
2. **`https://updates.bithuman.ai/` must serve the published files** over HTTPS.

> Verified 2026-06-05: the private key in the login keychain matches the baked-in
> `SUPublicEDKey`, and `generate_appcast` → `sign_update --verify` round-trips
> (exit 0). The signing chain is sound; what remains is escrow + hosting.

## 1. Escrow the signing key

> **Exported + validated 2026-06-05.** The private key was exported with
> `generate_keys -x` to `~/bithuman-sparkle-ed25519.key` (0600), and proven to
> reproduce signatures that verify against the baked-in `SUPublicEDKey`
> (`sign_update --verify` → exit 0). **REMAINING (manual):** move that file into
> 1Password (vault: bitHuman, item "Sparkle EdDSA signing key") and secure-delete
> the local copy — until then the only durable backup is still just this Mac.

The original always lived in the login keychain (`security`: service
`https://sparkle-project.org`, account `ed25519`) — a single point of failure,
because the public half is frozen in every install. Re-export (idempotent) with:

```bash
example/macos/Pods/Sparkle/bin/generate_keys -x ~/bithuman-sparkle-ed25519.key
chmod 600 ~/bithuman-sparkle-ed25519.key
# → 1Password, then secure-delete the local copy:
rm -P ~/bithuman-sparkle-ed25519.key
```

The export is a **44-char base64 string** (the 32-byte Ed25519 seed). Two ways to
use it elsewhere:
- **Restore into a keychain:** `generate_keys -f ~/bithuman-sparkle-ed25519.key`
- **Headless / CI signing (no keychain):** set `SPARKLE_ED_PRIVATE_KEY` to those
  44 chars (the file's exact contents). publish-macos.sh writes it to a temp file
  and passes `--ed-key-file` (verified: this format signs correctly).

## 2. Publish a new version (every release)

```bash
# a) bump the version — the BUILD number (after '+') MUST strictly increase;
#    Sparkle compares CFBundleVersion to decide "is there a newer build?"
#    example/pubspec.yaml:   version: 1.0.1+2     (was 1.0.0+1)

# b) build + notarize + sign + (re)generate the appcast, staged into dist/updates/
#    (DEVELOPMENT_TEAM=G64NFNZX84 is read from ~/.env via the publish step)
export UPDATES_DEPLOY_TARGET='r2:bithuman-updates'                  # the live host
export SPARKLE_ED_PRIVATE_KEY="$(cat ~/bithuman-sparkle-ed25519.key)"  # or from 1Password
set -a; . ~/.env; set +a    # CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID for the r2: upload

DEVELOPMENT_TEAM=G64NFNZX84 scripts/publish-macos.sh --deploy       # build → notarize → sign → appcast → upload → verify
#   …or split:  scripts/publish-macos.sh           (build only)
#               scripts/publish-macos.sh --skip-build --deploy   (reuse build, just ship)
```

`dist/updates/` is a 1:1 mirror of the site root. After deploy it contains:

```
dist/updates/
  appcast.xml                 # the signed feed every install polls
  bitHuman-1.0.0-1.dmg        # each published build (kept for binary deltas)
  bitHuman-1.0.1-2.dmg
  *.delta                     # auto-generated incremental updates (smaller dl)
  old_updates/                # pruned builds — do NOT upload
```

Keep old `.dmg`s in `dist/updates/` between releases so `generate_appcast` can
build binary deltas (much smaller downloads for users on the previous version).
Never hand-edit `appcast.xml` — re-run `publish-macos.sh` instead (edits break the
embedded signatures).

The script enforces the safety rails for you:
- **Monotonicity guard** — if you forget to bump the build number, it refuses to
  stage a build that's already published (instead of silently writing an appcast
  no install can use). Pass `--republish` only to deliberately re-sign the same
  build.
- **Atomic deploy** — enclosures upload before the appcast that references them,
  and the appcast is always served as `application/xml`.
- **Post-deploy verification** — after `--deploy` it HEAD-checks the live
  appcast and every enclosure URL, failing loudly if anything 404s.

## 3. Hosting `updates.bithuman.ai` — LIVE (Cloudflare R2)

> **Set up + verified live 2026-06-05.** `updates.bithuman.ai` serves the feed
> over HTTPS from a Cloudflare R2 bucket via a custom domain (the same mechanism
> as `models.bithuman.ai`). appcast.xml → `application/xml`, the dmg →
> `application/octet-stream` with `accept-ranges: bytes`; the live dmg matches
> the signed appcast.

Setup (already done — recorded so it's reproducible):
- **R2 bucket** `bithuman-updates` (account `97ec7ba3…`), holding `appcast.xml` +
  each `bitHuman-<ver>-<build>.dmg` at the bucket root.
- **Custom domain** `updates.bithuman.ai` attached to that bucket, zone
  `bithuman.ai` (`4cf99802608156eeac76f1fe89a608db`), Cloudflare-managed TLS.
- **Upload path:** the bucket's S3 keys are scoped to `bithuman-weights` only, so
  publish-macos.sh's `r2:` deploy target uploads via the Cloudflare **R2 REST
  object API** using `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` (both in
  `~/.env`). `aws s3` will NOT work against this bucket — use `r2:bithuman-updates`.

So a release is just step 2 above with `UPDATES_DEPLOY_TARGET='r2:bithuman-updates'`.

Smoke test:

```bash
curl -sI https://updates.bithuman.ai/appcast.xml   # 200, content-type: application/xml
# In the app:  menu → Check for Updates…   (or it auto-checks daily)
```

## Gotchas

- **arm64-only.** `generate_appcast` infers `sparkle:hardwareRequirements=arm64`
  from the bundle (the engine ships only Apple-Silicon slices). Intel Macs won't
  be offered updates — expected; they can't run the app anyway.
- **Sign AFTER stapling.** Stapling rewrites the dmg bytes; signing must come
  after (release-macos.sh / generate_appcast already do this — don't reorder).
- **Build number, not marketing version, gates the update.** `1.0.1` with build
  `+1` again will NOT be offered over `1.0.0+1`. Always bump `+N`.
- **First release can't "update from nothing."** Auto-update kicks in from the
  *second* published build onward; v1 users get v2 automatically.
- **CI signing:** set `SPARKLE_ED_PRIVATE_KEY` (from escrow) so no keychain/login
  is needed; publish-macos.sh prefers it over the keychain.
