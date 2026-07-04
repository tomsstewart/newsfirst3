# NewsFirst v3 — State of Play (handoff, 2026-07-04 ~19:30)

For the next Claude instance. Read alongside `DELIVERY_PLAN.md` (phases) and `../NewsFirst v3 Strategy.md` (why). Memory files in the project memory dir mirror this. Tom's overriding goal: **MRR (ambition raised to £10k/mo)**; hard budgets: app open < 1s, article open < 1s, flawless animations.

## Access / tooling (all working)
- **Repo**: github.com/tomsstewart/newsfirst3 (local `Claude workspace/newsfirst3`). Commit+push freely.
- **Supabase** `sbqdvtzsezxupxxbmjsb`: psql direct (`/opt/homebrew/opt/libpq/bin/psql`, password in memory file — Tom said stop nagging about it). CLI: SUPABASE_ACCESS_TOKEN is in the local memory file (newsfirst-v3-autonomous-session), NOT here; deploy: `supabase functions deploy ingest --project-ref sbqdvtzsezxupxxbmjsb --use-api`. Service key: `supabase projects api-keys` (also cached in scratchpad/.srk, may be gone).
- **iOS**: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; `xcodegen generate` in ios/ after adding files; build → `xcrun simctl install booted` → `launch` → `io booted screenshot`. iPhone 17 Pro sim stays booted.
- **Mac demo**: swiftc build (see git log for exact file list) → `demo/NewsFirstDemo --selftest` (regression: APIs, all 14 topics, all sources, custom topics) and `--snapshot`.
- **Gemini key** (in ingest secrets): free tier = **20 req/day**, resets 07:00 UTC. Never add billing.

## Built & verified
- **Pipeline**: 121 live-tested sources (67 added tonight); ingest cron 5-min (15 sources/tick, conditional GET, adaptive intervals, backoff + auto-fix, never silent-disabled); OG-image rescue 40/h; enrichment 1 Gemini call/2h (strict 1–2 topics); **daily AI briefs** cron 07:20 UTC (1 call → per-topic 2-3 sentence overviews → `briefs` table; client sparkle card built; **first briefs appear tomorrow** — today's quota was spent). 45-day retention (DB currently 14MB). Zero article UPDATEs by design (score computed at read via `feed` view).
- **App (SwiftUI, sim-verified)**: 3 views (List w/ priority bands + accordion expand; Immersive cards w/ bands; Full pager) · live 3-pane swipe carousel with **finger-tracked selection pill** (frame-interpolated, just shipped — verify feel) · cache-first store + in-memory image cache (sync-resolve, failure-cached) + neighbour prefetch · Load More pagination (30/page, server offset) · custom topics E2E · Topics⇄Sources slider; source links jump to source view · in-app reader (SFSafari, reader-mode toggle, no redundant X; WKWebView+cookie-blocker on Mac) · settings (appearance incl. **light mode**, default view, topics, drag-reorder chips, per-source toggles, priority debug) · onboarding (welcome→topic picker) · **email-OTP auth working** (AuthClient; Apple/Google stubbed) · PostHog REST analytics (install-UUID, alias on login; events: app_open, topics_selected, custom_topic_add, article_open, login_success).
- **Design**: Midnight Glass colours (Tom explicitly rejected Kinetic *colours*; Kinetic contributes type/spacing/rise only — rise plays on topic entry first-screenful only). 10pt gutters, 100pt thumbs. Motion: `.smooth`/easeInOut, no springs w/ overshoot, no blur anims.

## Immediate next steps (unblocked)
1. Verify finger-tracked pill feel + expanded-cell-on-launch quirk seen once in an old screenshot.
2. Egress optimization: delta feed fetch (only `published_at > newest cached`), cuts repeat-open egress ~80%.
3. Feed-health admin page (Cloudflare Pages/GitHub Pages + service-key-less view or authed role).
4. Brief card polish once real briefs land tomorrow; check `select * from briefs` after 07:20 UTC.
5. Breaking-news cluster velocity (entity overlap → cluster_id → promote ≥3 sources/45min) — schema ready.
6. iPad layout; light-mode placeholder polish; Instruments 120Hz trace on device.

## Blocked on Tom (the complete list of what's needed from him)
1. **Apple Developer portal** (~20 min): bundle `com.ant2555.newsfirst` — Push Notifications + Time-Sensitive entitlements, **APNs auth key (.p8)** → then I build the alert matcher (schema ready: `topic_subscriptions.notify_level`, `alerts` table, `devices`), notification service extension, render-from-payload open. **This is the product** — Phase 4.
2. **Sign in with Apple capability** (same portal visit) + Google OAuth client → activate the stubbed buttons.
3. **RevenueCat account** + App Store Connect API key → paywall (Pro £29.99/yr per plan) — Phase 5.
4. **TestFlight**: App Store Connect access to upload builds (v3 ships as UPDATE to existing app, version 2.0.0).
5. Run the app on a **real iPhone** for feel-check + launch-time verification (<1s budget; sim debug measured ~1.17s process-spawn — release/device will beat it, needs confirming).
6. Optional: reply to the OTP test code email is NOT needed; a code was sent to getyournewsfirst@gmail.com as proof it works.

## Supabase limits (Tom asked)
Current DB **14MB** / 500MB free cap; 45-day retention keeps steady state ~250-400MB at 121 sources — fits, monitor monthly. Edge invocations ~300/day vs 500k/mo — trivial. **Egress is the real ceiling**: ~5GB/mo free ≈ ~150 DAU at current fetch patterns (images don't count — they go via wsrv.nl). Delta-fetch (next step #2) roughly ×5s that headroom; beyond that Pro $25/mo (250GB) is the planned upgrade at revenue.

## Direction check (vs strategy)
On track: alerts-first architecture is fully staged (only APNs missing), topics are the spine, analytics identity fixed, monetisation gates designed. £10k MRR ≈ 4,200 subs — post-launch this is an **acquisition** problem (strategy §4.4 channel tests); product is no longer the bottleneck. Kill-gates from strategy §4.3 still apply at TestFlight.
