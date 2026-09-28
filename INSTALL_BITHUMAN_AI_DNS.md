# Setting up `install.bithuman.ai` (one-time DNS setup)

## ★THE LIVE WORKER (2026-09-28): it PROXIES, and `/windows` serves install.ps1

What runs today is the Cloudflare Worker `bithuman-install` (account-level
script, routed on `install.bithuman.ai/*`). It does not redirect: it fetches the
installer from this tap's `main` and serves it with `x-bithuman-upstream` naming
the file. Every path serves `install.sh`, except `/windows` (and `/windows.ps1`,
`/install.ps1`), which serves `install.ps1` as text/plain for
`irm https://install.bithuman.ai/windows | iex`. The deployed source, verbatim:

```js
// install.bithuman.ai — the bitHuman CLI installers, proxied from the public tap.
//   curl -fsSL https://install.bithuman.ai | sh          (macOS, Linux)
//   irm https://install.bithuman.ai/windows | iex        (Windows, PowerShell)
// Every path other than /windows keeps serving install.sh exactly as before.
const TAP = "https://raw.githubusercontent.com/bithuman-product/homebrew-bithuman/main/";

const ROUTES = {
  sh: {
    upstream: TAP + "install.sh",
    type: "text/x-shellscript; charset=utf-8",
    fallback: (u) => "curl -fsSL " + u + " | sh",
  },
  ps1: {
    upstream: TAP + "install.ps1",
    type: "text/plain; charset=utf-8",
    fallback: (u) => "irm " + u + " | iex",
  },
};

function routeFor(pathname) {
  const p = pathname.replace(/\/+$/, "").toLowerCase();
  return p === "/windows" || p === "/windows.ps1" || p === "/install.ps1" ? ROUTES.ps1 : ROUTES.sh;
}

export default {
  async fetch(request) {
    const method = request.method;
    if (method !== "GET" && method !== "HEAD") {
      return new Response("method not allowed\n", { status: 405 });
    }
    const route = routeFor(new URL(request.url).pathname);
    const upstream = await fetch(route.upstream, { cf: { cacheTtl: 300 } });
    if (!upstream.ok) {
      const msg =
        "bitHuman installer temporarily unavailable; use:\n  " + route.fallback(route.upstream) + "\n";
      return new Response(method === "HEAD" ? null : msg, {
        status: 502,
        headers: { "content-type": "text/plain; charset=utf-8" },
      });
    }
    // A HEAD response must carry no body.
    return new Response(method === "HEAD" ? null : upstream.body, {
      status: 200,
      headers: {
        "content-type": route.type,
        "cache-control": "public, max-age=300",
        "x-bithuman-upstream": route.upstream,
      },
    });
  },
};
```

Deploy with the Workers API (`PUT /accounts/<acc>/workers/scripts/bithuman-install`,
module `index.js`, compatibility_date `2026-09-01`, no bindings), then verify both
routes: `curl -sI https://install.bithuman.ai` names `install.sh` and
`curl -sI https://install.bithuman.ai/windows` names `install.ps1`.

The sections below are the original (2026-09) setup notes, kept for the record.

---

The curl installer for the bithuman CLI lives at:

    https://raw.githubusercontent.com/bithuman-product/homebrew-bithuman/main/install.sh

To shorten that to the friendlier `https://install.bithuman.ai`, configure a
Cloudflare Worker (or page rule) on the `bithuman.ai` zone. Until then, docs
should advertise the raw URL. It is the ONLY one that works — see
"the asset URL does not work" below.

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

### ★The asset URL does NOT work, and this file used to say it did

Until 2026-09-13 this section offered a fallback:

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

So there is ONE installer URL, the raw one at the top of this file, and a
redirect to it is the only shortening that can be correct. Do not re-add an
asset-URL fallback without first attaching `install.sh` to the CLI release AND
pinning the tag — a fallback that 404s is worse than no fallback, because it
is reached exactly when the primary is already failing.
