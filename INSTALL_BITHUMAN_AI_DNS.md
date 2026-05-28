# Setting up `install.bithuman.ai` (one-time DNS setup)

The curl installer for the bithuman CLI lives at:

    https://raw.githubusercontent.com/bithuman-product/homebrew-bithuman/main/install.sh

To shorten that to the friendlier `https://install.bithuman.ai`, configure a
Cloudflare Worker (or page rule) on the `bithuman.ai` zone. Until then, docs
should advertise the raw URL or the `releases/latest/download/install.sh`
asset URL (both are live today).

---

## Option A — Cloudflare Worker (recommended)

1. Open **Cloudflare → bithuman.ai → Workers & Pages**.
2. Create a worker named `bithuman-install` with this code:

   ```js
   export default {
     async fetch(request) {
       const url = new URL(request.url);
       // Preserve any path/query so e.g. `install.bithuman.ai?foo` still works.
       return Response.redirect(
         "https://raw.githubusercontent.com/bithuman-product/homebrew-bithuman/main/install.sh",
         302,
       );
     },
   };
   ```

3. Under **Workers Routes**, map `install.bithuman.ai/*` to the worker.
4. Under **DNS**, add a proxied A or CNAME record for `install` so Cloudflare
   handles the hostname:
   - CNAME `install` → `bithuman.ai` (proxied)
   - or A `install` → `192.0.2.1` (proxied; placeholder IP, Workers intercepts)

5. Verify:

   ```sh
   curl -sIL https://install.bithuman.ai | head -5
   ```

   Should show a 302 to the raw GitHub URL and a final 200.

   ```sh
   curl -sSL https://install.bithuman.ai | sh -s -- --help 2>/dev/null || \
     curl -sSL https://install.bithuman.ai | head -3
   ```

   Should show the installer's `#!/bin/sh` header.

---

## Option B — Cloudflare Page Rule (no worker)

1. **DNS**: add a CNAME `install` → `raw.githubusercontent.com` (proxied).
2. **Rules → Page Rules**: create
   - URL: `install.bithuman.ai/*`
   - Setting: *Forwarding URL* → `302 - Temporary Redirect`
   - Destination: `https://raw.githubusercontent.com/bithuman-product/homebrew-bithuman/main/install.sh`

Caveat: Page Rules are being deprecated in favour of Single Redirects /
Workers — prefer Option A for anything new.

---

## Why redirect (and not host the script on Cloudflare directly)

The canonical script lives in this tap repo's `main` branch — every push
updates it instantly. A redirect keeps the installer single-sourced and
auditable in git; Cloudflare just shortens the URL.

If GitHub raw is ever flaky, the equivalent asset URL also works:

    https://github.com/bithuman-product/homebrew-bithuman/releases/latest/download/install.sh

(That URL serves `install.sh` if it's been uploaded as a release asset on
the latest release — the publish workflow attaches it on every tag.)
