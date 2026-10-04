// install.bithuman.ai — the bitHuman CLI installers, proxied from this repository's main branch.
//   curl -fsSL https://install.bithuman.ai | sh          (macOS, Linux)
//   irm https://install.bithuman.ai/windows | iex        (Windows, PowerShell)
// Every path other than /windows serves install.sh.
//
// Source of the Cloudflare Worker `bithuman-install` (account-level script, routed on
// install.bithuman.ai/*). Deploy: INSTALL_BITHUMAN_AI_DNS.md. The upstream is GitLab, the
// repository's home since the 2026-10 move; the scripts it serves read releases from
// https://downloads.bithuman.ai/homebrew-bithuman and make no GitHub request.
const TAP = "https://gitlab.com/bithuman/sdk/homebrew-bithuman/-/raw/main/";

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
