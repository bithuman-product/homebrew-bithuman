# bitHuman Apps — Production Readiness Design (macOS + iOS)

**Status:** Draft for review · **Date:** 2026-06-02 · **Scope:** Turn the Flutter `example/` developer demo into a shippable consumer app for the **Essence** (lightweight) and **Elevate** (photoreal) engines, backed by the existing `lafayette` platform.

> This is a design doc only. No code has been written. Implementation begins after sign-off, phase by phase, each phase gated on the verification criteria in §10.

---

## 0. Decision log (locked 2026-06-02)

| # | Decision | Choice | Consequence |
|---|----------|--------|-------------|
| D1 | App Store payment strategy | **macOS off-store** (Developer ID + notarized) **+ iOS US-external-link, Apple IAP fallback elsewhere** | bithuman.ai checkout is fully legal on macOS + US iOS; non-US iOS needs IAP consumable packs |
| D2 | Umbrella cloud-key shape | **Server-minted ephemeral OpenAI token now, proxy later** | Smallest client diff; metering is partly client-timed until the proxy lands |
| D3 | Auth model | **Reuse the LIVE `bithuman login` device-auth flow** (`/v1/cli/auth/*`, loopback-PKCE / device-code → revocable per-device api-secret) — *revised 2026-06-02, supersedes the `/v2/auth/mobile/token` + clerk_flutter plan* | No in-app Clerk SDK / publishable key; reuses deployed, tested infra; per-device revocable keys; SiwA happens on the web sign-in page |
| — | Lower-stakes defaults (no objection raised) | App-scoped pricing rows `cloud=10/local=1`; free **recurring Stripe price** for 99/mo refill; versioned **`/v1/agents`** endpoint | Avoids overloading existing rates; reuses renewal-reset machinery; decouples app from the marketing site |

**Still need product/legal sign-off (see §11):** Elevate local-session packaging & rate eligibility; whether 10 cr/min covers OpenAI cost; current Apple external-link commission %; in-app account-deletion requirement.

---

## 1. Current state (one paragraph per layer)

- **App** (`example/lib/`, ~3,850 LOC): a single-screen `MaterialApp(home: AvatarScreen())` (`main.dart:58-75`) using plain `setState` in a 2,300-line `_AvatarScreenState`. **No** auth, accounts, credits UI, IAP, router, or splash. Credentials come from a 4-layer chain (hardcoded → `--dart-define` → `config.json` → Settings sheet). `dev_secrets.dart:20` holds a live-format OpenAI key **in the working tree only** (verified: not in any of 195 commits, `skip-worktree` set — rotate it, but no history rewrite needed).
- **Transports** (`realtime_transport.dart`): one Dart interface, three sessions — **cloud WebSocket** (macOS, `bithuman_realtime.dart`) and **cloud WebRTC** (iOS, `openai_webrtc_session.dart`) both dial `api.openai.com` directly with the user's key; **local** (`LocalConverseTransport` → on-device Qwen+Supertonic, zero OpenAI). Single start/stop boundary: `main.dart:_toggleSession` (286) / `_stopSession` (397). **No duration tracking, no billing call anywhere.**
- **Gallery primitives already shipped, unused**: `lib/bithuman.dart` defines `BithumanAgent`, `fetchPublicAgents()` (`:254`, hits `www.bithuman.ai/api/agents?type=community`) and `downloadAgentImx()` (`:281`, IMX-magic-validated). `main.dart` imports them but calls none.
- **Voices** (`voices.dart`): 20 static `VoicePersona`s (10 cloud, 10 local), **each already carries a `female` bool**. Initial voice is a hardcoded constant per runtime, never randomized.
- **Backend** (`platform/services/`): identity is **Clerk** (web only) mirrored into Supabase `users` by a webhook (`auth-service/v2/clerk_webhook.py`); per-user **api-secret** scheme + HS256 runtime/embed JWTs. **`billing-service` owns a real per-minute credit ledger** (two pools: plan + top-up) with **Stripe** fully wired; rates are DB-driven (`pricing` table) and already split cloud vs self-hosted. The platform **already falls back to its own `OPENAI_API_KEY`** (umbrella) when no BYOK is set. **Gaps:** no mobile token→api-secret endpoint, no monthly free-credit refill, no client-mintable checkout URL, no versioned catalog/list endpoint.

---

## 2. Target architecture

```
                        ┌─────────────────────────── Flutter app (macOS / iOS) ───────────────────────────┐
                        │  Splash → Auth gate → AvatarScreen                                              │
                        │  ┌── AppStore (ValueNotifier): session, credits, user, storefront ──┐           │
   social login         │  │  CreditsCounter   GalleryScreen   UpgradeButton   VoicePicker     │           │
   (Clerk SDK + SiwA) ──┼─▶│                                                                   │           │
                        │  └───────────────────────────────────────────────────────────────────┘           │
                        └───────┬───────────────┬───────────────────┬───────────────────┬──────────────────┘
                                │ Clerk JWT      │ api-secret hdr     │ ephemeral token   │ public model_url
                                ▼                ▼                    ▼                   ▼
                   POST /v2/auth/mobile/token   /v2/credit-summaries  POST .../mint-     GET /v1/agents
                   (NEW, JWKS verify→mint)      /v2/cloud-runtime/    realtime-token     (NEW list)    Supabase
                        │                       receive-events (meter) (NEW)             public bucket .imx
                        ▼                                │                  │
                   auth-service ───── api-secret ──▶ billing-service ◀── ephemeral session start = meter seed
                   (Clerk JWKS verify,              (credit ledger,        │
                    create-on-miss, mint)            pricing rows,         ▼
                                                     99/mo refill)    OpenAI Realtime (Bearer = ephemeral)
```

**Principle preserved:** the app never embeds a long-lived secret. After login it holds a per-user **api-secret** (in `flutter_secure_storage`) used to call bitHuman; cloud OpenAI access uses a **per-session ephemeral token** minted on demand. The existing Engine→SDK→App rail is untouched.

---

## 3. Cross-cutting foundations (Phase 0)

These are decision-independent and unblock everything else.

### 3.1 Security
- **Rotate** the OpenAI key currently in `dev_secrets.dart:20` (working-tree only; no public leak). Blank the file once §4 lands; keep `skip-worktree`.
- **Never** persist account credentials to plaintext `config.json` (`dev_config.dart:198-238`). Add **`flutter_secure_storage`** for the api-secret; ephemeral tokens stay in memory.
- **Trust boundary:** the mobile flow must present a **verifiable token** (Clerk JWT, checked via JWKS). It must **never** assert its own `user_id` — i.e. do **not** reuse the web BFF's `x-user-id` trust (`v2/api_secrets.py:_get_requester_user_id`), which is an account-takeover hole if exposed to mobile.
- Mint/validate via the **strict** `v2.api_secrets.validate_credentials_and_get_key` (checks `users.api_secrets`), **not** the loose `utils.validate_credentials_and_get_id` (accepts any 32-char prefix-decodable key).

### 3.2 App architecture refactor (do before piling on features)
The 2,300-line `setState` god-widget can't absorb auth + credits + gallery + paywall cleanly. Introduce, minimally:
- A **router** (2+ routes: Splash, Login, Avatar, Gallery) replacing `home: AvatarScreen()` (`main.dart:58-75`).
- A small **store** — a couple of `ValueNotifier`s / one `InheritedWidget` (`Auth`, `Credits`) — rather than a new state-mgmt dependency. Cross-cutting reads (`CreditsCounter`, auth gate) subscribe; `_AvatarScreenState` keeps its session-local fields.

### 3.3 Region / storefront detection (needed by R3/R7)
One reusable utility returning the device App Store country (StoreKit `Storefront.countryCode` on iOS; not applicable on macOS off-store build). Drives the US-vs-rest upgrade-button gating in one place.

### 3.4 New dependencies (`example/pubspec.yaml`)
| Package | For |
|---------|-----|
| `dio` (or `http`) | all backend calls (none today) |
| Clerk Flutter SDK + `sign_in_with_apple` + `google_sign_in` | R1 login + Guideline 4.8 |
| `flutter_secure_storage` | api-secret at rest |
| `url_launcher` | R3 external checkout |
| `connectivity_plus` | R6 WiFi/cellular gating |
| `background_downloader` | R6 true OS-level background downloads |
| `in_app_purchase` | R3/R7 non-US iOS IAP fallback |
| `flutter_native_splash` + `flutter_launcher_icons` | R7 branded splash + icon |

---

## 4. R1 — Social login + umbrella account + free 99/mo

> **⚠️ REVISED 2026-06-02 — auth approach pivoted (see D3).** Instead of a new `/v2/auth/mobile/token` endpoint + the `clerk_flutter` SDK, the app **reuses the already-LIVE `bithuman login` device-auth flow** (`auth-service/v2/cli_auth.py`, endpoints `POST /v1/cli/auth/{start,token,revoke}`, frontend pages `bithuman.ai/{cli/authorize,activate}`, spec in `AUTH-CLI-LOGIN-DESIGN.md`). The app uses the **device-code** variant (reliable on macOS + iOS): generate PKCE → `POST /v1/cli/auth/start` (`client_name`, no redirect) → open `verification_uri_complete` in the browser → user signs in (Clerk: Google/email/Apple) + approves → poll `POST /v1/cli/auth/token` (PKCE-proven) → receive a **revocable per-device api-secret** (alias `cli@<host>-<ts>`), stored in `flutter_secure_storage`. **No in-app Clerk SDK, no publishable key, no new mint endpoint.** Implemented in `example/lib/auth_service.dart`. Sign in with Apple is satisfied on the web sign-in page. *Nicer-UX follow-ups: loopback-PKCE auto-return on macOS; ASWebAuthenticationSession + a custom-scheme redirect on iOS (needs a small addition to the loopback-only `/cli/authorize` page).* The free-99/mo refill (below) is unchanged. The original `/v2/auth/mobile/token` design is retained below for history but is **not** being built.

**Verdict: Feasible-with-changes (XL). Net-new backend endpoint + monthly refill mechanism.**

### Backend
1. **New endpoint `POST /v2/auth/mobile/token`** (register router in `auth-service/main.py` near the `include_router` calls at `:104-107`):
   - Accept `Authorization: Bearer <Clerk session JWT>`.
   - **Verify networklessly via JWKS** — port the only existing pattern, `supabase/functions/halo-telemetry-ingest/index.ts:resolveUserId` (jose `jwtVerify` + `createRemoteJWKSet` against `CLERK_JWKS_URL`/`CLERK_JWT_ISSUER`), into Python (`PyJWT` + `jwt.PyJWKClient`). Extract `sub` = clerk id.
   - **Resolve/create** the Supabase user via `billing-common/db.py:get_user_by_clerk_id`, **creating on miss** (the webhook may not have fired yet for a brand-new signup — closes the provisioning race). Provision subscription/Stripe via the existing `_ensure_user_subscription_and_stripe` path used by the webhook.
   - **Idempotently mint** an api-secret via `v2/api_secrets.py:create_api_secret` (`append_api_secret` RPC), returning an existing `mobile`-aliased secret if present. Return `{ api_secret, user_id, plan }`.
2. **Free 99/mo refill** (none exists today): set `monthly_credits = 99` on the `membership_free` pricing row and back it with a **free recurring Stripe price**, so the existing renewal path (`stripe_webhooks.py` renewal → RPC `p_reset=True`, ~`:2153`) resets it monthly with **no new scheduler**.
3. **Unify the free-allowance source of truth:** `agent-worker/billing/multi_app.py:initialize_user_app_subscription:67` hardcodes `199` — change to source from `pricing.monthly_credits` (→ 99). Removes the 199-vs-`monthly_credits` divergence.

### App
- Clerk Flutter SDK (or native providers) for social login; **`sign_in_with_apple`** (mandatory on iOS per 4.8 since Google is offered).
- On login success → call `/v2/auth/mobile/token` → store api-secret in `flutter_secure_storage`.
- **Auth gate**: wrap/replace `home:` (`main.dart:58-75`) so unauthenticated users see Login; authed users see `AvatarScreen`.
- Replace credential sources: `DevConfig.bithumanApiSecret` (`dev_config.dart:46`) and the OpenAI key (`dev_config.dart:30-39`) become **server-issued** — populate `resolvedOpenAIKey` (already the runtime indirection point, set at `main.dart:154`) and a new `resolvedBithumanSecret` from the session/ephemeral responses. Retire `_FirstRunScreen`/`_EnvKeyHint` (`main.dart:924-1061`) for the consumer build.

### Risks
- Provisioning race (handled by create-on-miss).
- Native SiwA needs its own nonce/identity-token verification **if not funneled through Clerk** — funnel through Clerk to avoid a second verification path.

---

## 5. R5 + umbrella key — metering & ephemeral tokens

**Verdict: Needs-decision resolved (D2/D4); L. Backend mint + pricing rows + client reporting.**

### Umbrella key (D2 = ephemeral now)
- **New endpoint** to mint a **per-session OpenAI Realtime ephemeral token** (`client_secret`), gated on the api-secret. The app fetches it at **`realtime_transport.dart:pickTransport` (`:428`)** before constructing a cloud session and passes it as the Bearer value. The two send sites — `bithuman_realtime.dart:_connectAndConfigure` (`:155-160`) and `openai_webrtc_session.dart:_negotiateWithOpenAI` (`:201`) — are **structurally unchanged** (still `Bearer <token>`; only the value differs). Local sessions need no token.
- The mint call **doubles as the server-authoritative session-start signal** (proves bitHuman authorized this session) → seeds metering.
- *Later (proxy):* swap the `wss://…/v1/realtime` / `https://…/v1/realtime/calls` URLs to a bitHuman proxy for server-authoritative duration — no app-UI change.

### Rates (D4 = app-scoped rows)
- Add **app-scoped `pricing` rows** `cloud = 10 cr/min`, `local = 1 cr/min` rather than overloading existing rows (essence_cloud=2, voice=10, video=30). The metering math is data-driven (`billings.py:_get_pricing_rate`) — **no code change** to the calc.
- Update the **`minutes_estimate` divisors** in `/v2/credit-summaries` (`billings.py` ~`:1500-1529`) to include the new rates, or "minutes remaining" will display wrong.

### Client reporting & crash safety
- Capture session start/tier at **`main.dart:_toggleSession` (~`:357`, after `start()` succeeds)** — it's the one place that knows both the transport and `_localMode` (the rate flag). Stop edge at **`_stopSession` (~`:409`)** computes elapsed × rate and POSTs a usage event (reuse `/v2/cloud-runtime/receive-events` or a sibling mobile endpoint; **server computes minutes** per the existing 60s heartbeat model).
- **Crash/force-quit safety:** add a `WidgetsBindingObserver` lifecycle hook + periodic flush so a session that never hits `_stopSession` still bills. Pair with the **server-side ephemeral-token-at-start + stop signal** so billing doesn't depend solely on a Dart timer. (Optional native boundary: `RealtimeAudioIO.swift` start/stop `:350/:376` covers WS-cloud + local but **misses iOS WebRTC cloud** — not sufficient alone.)
- **Reconnect:** the WS path auto-reconnects; measure duration from the single `_open` true→false edge, not per-connection, or it over-bills.

### Risks
- Client-only metering is **spoofable** (key hits OpenAI directly) and **lossy on crash** → proxy is the eventual hardening (D2 "later").
- OpenAI **token cost is not metered into credits today**; confirm 10 cr/min actually covers Realtime spend (§11).
- "Local Elevate" tier eligibility unverified (§11).

---

## 6. R4 — Credits live in the control panel

**Verdict: Feasible-with-changes (M).**
- App: add `_credits` to the store (§3.2); render in the **top-chrome Row** (`main.dart:605-640`, already SafeArea + fade-aware). Subscribe in `initState`, tear down in `dispose` (mirror `_sessionSub` at `:87-91`, `:397-407`). Read `/v2/credit-summaries`.
- **Enforcement:** add a credits check beside the existing key check in `_toggleSession` (`:286-297`) — if `credits <= 0`, short-circuit and show the low-credits prompt (§7) instead of starting.
- **"Instant" feel:** server deducts on a 60s heartbeat, so a naive poll looks laggy mid-session. Use an **optimistic local decrement** (tier × elapsed) reconciled against the authoritative server number; hard-refresh after login, after each `_stopSession`, and after returning from the upgrade browser.

---

## 7. R3 — Low-credits → upgrade (storefront-gated)

**Verdict: Needs-decision resolved (D1); M.**
- **Backend:** no client-mintable checkout URL exists (Stripe checkout lives in the Next.js `/api/stripe/topup-*` routes). Add a **`create-checkout-session`** endpoint to `billing-service` returning a hosted URL (the `auto_charge.py` flow already knows how to create Stripe sessions).
- **App:** add an **"upgrade / buy credits"** affordance in the top chrome + a low-credits prompt at the `_toggleSession` gate. Reuse `_TopToast` (`main.dart:555-568,1784-1873`) for the non-blocking nudge; a full-screen paywall follows the `_ModelDownloadOverlay` pattern.
- **Storefront gating (D1):** show the **external `url_launcher` → bithuman.ai** button **only when storefront == US** (and always on macOS off-store). **Non-US iOS → Apple IAP consumable credit packs** (`in_app_purchase`).
- After returning from the browser/IAP, **re-fetch `/v2/credit-summaries`** so the balance reflects the purchase (account-linked sync).

### Risks
- External-link button shown globally = rejection in most countries — the storefront gate is mandatory.
- A US external-link commission is expected to become non-zero on remand (currently 0%) — budget for it (§11).

---

## 8. R2 + R6 — Gallery, voices, downloads

**Verdict: Feasible-with-changes (L each).**

### R2 Gallery & voices
- **Backend:** add a versioned **`GET /v1/agents`** in `public-api-service/main.py` (before the proxy catch-all ~`:1893`): query Supabase `agents` for `visibility in ('public','demo')` + `status.state='ready'`, returning `name/thumbnail/gender/category/model_url/model_size` with `limit/offset`. Add `thumbnail_path` + a **model file-size** column (capture byte size at `utils.py:upload_to_supabase_storage:427`; extend the select in `get_agent_data:1063`). This decouples shipped apps from the marketing-site route.
- **App gallery screen:** a new `GridView` route calling `fetchPublicAgents()` (`bithuman.dart:254`) → thumbnail+name+gender cards → on tap `downloadAgentImx()` (`:281`) with progress → `BithumanAvatar.load` + `_onAvatarLoaded` (`main.dart:235-253/267`), optionally applying the agent's `systemPrompt`/`voiceId`. Parse `gender/thumbnail/size` in `BithumanAgent.fromJson` (`:238`).
- **Multi-avatar storage:** today `resolveImxPath` assumes a single `<app-support>/avatar.imx`. Add per-id caching `<app-support>/agents/<id>.imx` + an **active-agent pointer** ahead of the single-file resolution (`dev_config.dart:254/268`), plus a **local gallery** view of downloaded agents.
- **Both engines:** wire for Essence (.imx today) and Elevate — **confirm Elevate shares the same catalog/packaging** (§11).
- **Random voice by gender:** add `randomVoiceFor({required bool local, required bool female})` in `voices.dart` (`:57-62`) filtering `voicesFor(local:)` by `.female` via `dart:math`. Call at `_voiceCloud`/`_voiceLocal` init (`main.dart:115-116`), **persist the pick once** to `config.json` (don't re-randomize each boot), still honoring `config.json` overrides (`:149-150`). Gender source = the agent's `gender` (now parsed) or a user choice.

### R6 Downloads & WiFi
- **`connectivity_plus`** + a Wi-Fi/cellular confirmation prompt gating large fetches (local models ~852 MB; avatars ~120 MB). No metered gating exists today.
- **True OS-level background downloads** via `background_downloader` (or native `URLSession` background config) — current `downloadAgentImx`/`_fetchTo` run in-process (die on app suspend) and have **no resume** (delete `.part`, refetch whole). Add a **progress callback** to `downloadAgentImx` (`:281`, currently `res.pipe()` with no ticks) feeding the existing `_dlProgress` overlay; add **HTTP Range resume**.
- **Seed up to 5 showcase agents:** `fetchPublicAgents(limit:5)` (or the showcase route) → batch download (cap 5) with per-agent progress (the single `_dlProgress` overlay is sequential; generalize for concurrent).
- **Fix showcase drift:** the hardcoded code list (`imaginex-ui/app/api/agents/showcase/route.ts:5`) is already out of sync with the live site (`A23WJF0199` vs live `A23VKQ6520`). Drive it from an **`is_showcase`/`is_featured` DB flag** (or `/v1/agents?featured=true`).

---

## 9. R7 — Splash, branding, animation & App Store release

**Verdict: branding low-risk (L); payment-routing is the compliance crux (resolved by D1).**

### Branding / UX (easy)
- Branded **splash/hero route** mounted before `AvatarScreen` (`main.dart:58-75`); add `flutter_native_splash` + `flutter_launcher_icons` (neither configured) and a **logo asset** (none exists).
- **bitHuman logo top-left** in the top-chrome Row (`:605-640`).
- **Never-frozen:** all auth/metering/downloads are async/off the UI thread; reuse `_EngineLoadingOverlay`/`_ModelDownloadOverlay`/`_TopToast` and add vivid (but cheap) transitions. The existing animated call-status/model-load rings (recent commits) set the bar.

### Release plan (D1)
- **macOS:** ship **outside the Mac App Store** — Developer ID signing + **notarization** (DMG; optional Sparkle auto-update). IAP rules don't apply; bithuman.ai checkout is fully legal, commission-free.
- **iOS:** App Store submission with:
  - **Storefront-gated upgrade**: US → external link; non-US → **IAP consumable credit packs**.
  - **Sign in with Apple** offered alongside Google (Guideline **4.8**).
  - **In-app account deletion** (Apple requires it once accounts exist — verify, §11) — wire to a backend delete (the webhook already handles `user.deleted`).
  - **Privacy nutrition labels**; **no ATT prompt** needed for first-party login/credits.
- **Compliance hygiene:** never frame credits as license keys/codes/gift cards/vouchers (closes the 3.1.1 loopholes); IAP-purchased credits **must not expire**; consuming web-bought credits is fine but IAP must be offered where IAP applies.
- **Free download worldwide is approvable**; routing to bithuman.ai for *registration* is fine everywhere.

---

## 10. Phasing & verification (goal-driven)

Each phase ships behind the previous and is **done only when its checks pass**.

| Phase | Deliverables | Verify (success criteria) |
|-------|-------------|---------------------------|
| **0 — Security & scaffold** | Rotate key; blank/secure secrets; add deps; router + `ValueNotifier` store; storefront/region util | App builds & runs unchanged; no key in working tree; storefront util returns correct country; routes navigable |
| **1 — Identity & umbrella (R1)** | `/v2/auth/mobile/token` (JWKS→mint, create-on-miss); ephemeral-token mint endpoint; app Clerk+SiwA login, secure storage, auth gate; replace DevConfig key sources | Fresh user social-logs-in → app gets api-secret → **cloud session starts with an ephemeral token, zero hardcoded keys**; SiwA works on iOS |
| **2 — Credits & metering (R4,R5)** | Pricing rows `cloud=10/local=1` + `minutes_estimate` fix; free 99/mo refill; unify 199→99; live counter; low-credits gate; start/stop reporting + crash-safe flush | 1 cloud min → balance −10; 1 local min → −1; counter updates within a heartbeat (optimistic immediately); `credits<=0` blocks start; force-quit mid-session still bills |
| **3 — Gallery, voices, downloads (R2,R6)** | `/v1/agents` + `is_showcase` flag; gallery GridView + multi-avatar store + local gallery; gender-random voice (persisted); WiFi prompt + background downloads + resume; seed 5 showcase | Browse → download an agent over WiFi with progress → switch avatars; cellular triggers prompt; relaunch keeps voice; 5 showcase seeded on first run |
| **4 — Monetization, branding, store prep (R3,R7)** | `create-checkout-session`; upgrade button (US `url_launcher` / non-US IAP) + balance re-sync; splash/logo/animations; macOS notarized DMG; iOS TestFlight w/ SiwA + storefront gating + account deletion + privacy labels | US iOS shows external link, non-US shows IAP, both top up & re-sync balance; macOS DMG notarizes & launches; splash shows logo; TestFlight build accepted |

---

## 11. Open items needing sign-off (before/at relevant phase)

1. **Elevate local session** — *Resolved (2026-06-02):* Elevate artifact download is coming later; for now the gallery/local-model code uses **placeholders** for Elevate artifacts (real download path TBD). The verified on-device path remains the Essence/Qwen+Supertonic converse path. *R2/R5 for Elevate ship behind placeholders.*
2. **Does 10 cr/min cover OpenAI Realtime cost?** ⚠️ *Verified (2026-06-02) — likely NOT under realistic assumptions.* Credit value is **$1 = 100 credits ⇒ 1 cr = $0.01**, so cloud at 10 cr/min = **$0.10/min revenue**, and 1,800 credits = **$18** (top-up) / the Creator plan is **$20/mo for 1,800 credits**. `gpt-realtime-mini` realistic cost is **~$0.16/min (short prompt) to ~$0.33/min (1k-word system prompt)** — so 3 hrs (180 min) ≈ **$29–$59**, i.e. **1,800 credits covers ~1–1.9 hrs of OpenAI cost, not 3**, and the rate is **underwater on OpenAI alone by ~1.6×–3.3×** before bitHuman's own render/infra cost. Note: 10 cr/min already equals the platform's **existing voice-chat rate**. **OpenAI token cost is not metered into credits today**, so real margin is unmeasured. *Action (Phase 2): instrument actual per-session OpenAI token usage and measure real $/min before locking the rate; levers = short/cached system prompts, aggressive prompt caching (cached audio is 98%+ off), bounded context, idle timeout. Pending product decision: keep 10, raise the cloud rate, or measure-then-set.*
3. **Apple external-link commission %** at ship time (currently 0% in the US on remand; evolving). Get **legal sign-off**. *Phase 4.*
4. **In-app account deletion** requirement confirmation + backend delete wiring. *Phase 4.*
5. **macOS distribution channel** — DMG + Sparkle vs. other? (Off-store is decided; mechanism is open.) *Phase 4.*

---

## 12. Effort summary

| Req | Verdict | Effort |
|-----|---------|--------|
| R1 social login + umbrella + 99/mo | Feasible-with-changes | **XL** |
| R2 gallery + local download + random voice | Feasible-with-changes | L |
| R3 low-credits → upgrade | Resolved (D1) | M |
| R4 live credits in UI | Feasible-with-changes | M |
| R5 cloud 10 / local 1 metering | Resolved (D2/D4) | L |
| R6 WiFi prompt + bg downloads + seed 5 | Feasible-with-changes | L |
| R7 splash/branding + store release | Resolved (D1) | L |

**Overall: FEASIBLE.** ~70% of the backend plumbing already exists; the genuinely net-new work is the mobile auth-mint endpoint, the ephemeral-token mint, the monthly free refill, the versioned catalog endpoint, and the app's missing consumer surfaces (auth gate, credits, gallery, paywall, splash) — plus the macOS notarization + iOS storefront-gated monetization for release.
