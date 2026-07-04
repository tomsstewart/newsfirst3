# NewsFirst v3 — Delivery Plan

**Date:** 4 July 2026\
**Status:** decisions locked, foundation built, execution started\
**Companion:** `NewsFirst v3 Strategy.md` (the why); this document is the what/when/who.

---

## 0. Locked decisions (changes from the strategy doc in bold)

| Area | Decision |
|---|---|
| Platform | **Native SwiftUI, iPhone-first** (was Expo-leaning). Android deferred indefinitely; revisit only on iOS MRR. |
| Reader UI | Beautiful, but **explicitly not the hot path** — alerts → article open is the hot path; the feed is the retention surface. |
| Free tier | **3 custom topics** + all preset topics, daily-digest notifications, full feed with infinite scroll. |
| Pro tier | £29.99/yr / £3.99/mo, 7-day trial: unlimited custom topics, **instant** (time-sensitive) alerts, custom sources (later), richer AI briefs. |
| Notification control | **Per-topic notify level: `none` / `high` (high-priority only) / `all` (every match)** — first-class product feature, already in the schema. |
| Ingestion | Self-crawled RSS (58 curated v2 feeds carried over) + **Google News RSS query feeds per custom topic** for long-tail coverage. |
| Backend | New Supabase project `sbqdvtzsezxupxxbmjsb` (Postgres 17.6). Data API on, tables explicitly exposed, RLS everywhere, read-time scoring. |
| Ingest compute | Cloudflare Worker on cron (free tier), service key held only in Worker secrets. |
| AI enrichment | Gemini Flash-Lite (free tier, batched) for topics/entities/regions at ingest. |
| Payments | RevenueCat over StoreKit 2; Apple Small Business Program (15%). |
| Analytics | Existing PostHog project; install-UUID identification from first launch; full alert funnel (`notif_sent/delivered/opened`) server- and client-side. |

## 1. Principle zero: speed and smoothness are the product

Every phase gates on these budgets — they are acceptance criteria, not aspirations:

| Metric | Budget | How enforced |
|---|---|---|
| Cold start → first feed frame | **< 400ms** (target 300) | Measured every build on-device; no network on the render path — feed renders from the on-device cache, refreshes behind. |
| Notification tap → article visible | **< 1s cold, < 300ms warm** | Article payload rendered directly from the push; image pre-cached by a Notification Service Extension at receipt time. |
| Scroll (List + Immersive) | **120Hz, zero dropped frames** in Instruments on a ProMotion device | `LazyVStack`/paging with pre-warmed images; no layout work during scroll; Instruments trace per release. |
| View switching | **< 100ms** | Both views share one article store; switching is a presentation change, never a refetch. |
| Animation | Spring-based, interruptible, 120Hz | SwiftUI transactions; no `DispatchQueue.main.asyncAfter` choreography. |

Native SwiftUI makes these the default rather than an achievement — that's why we chose it. Any feature that breaks a budget gets cut or deferred, not shipped slow.

**Live iteration answer:** SwiftUI **Previews** give per-view hot reload in Xcode (instant, stateful, multiple devices/dark mode side-by-side) and **InjectionIII / the Inject package** gives in-simulator hot reload of the running app (edit → save → running screen updates in ~1s, no rebuild). Both are wired into the scaffold. This closes most of the Expo-fast-refresh gap.

## 2. Architecture (as now built/being built)

```
58 RSS feeds + Google News query feeds (per custom topic)
   │ Cloudflare Worker cron (adaptive per-feed polling, conditional GET)
   ▼
parse → normalise/dedupe (url_hash) → Gemini enrich (topics/entities/regions, batched)
   → base_score (write once) → INSERT via PostgREST (service key in Worker secret)
   │
   ├─ alert matcher: new article × topic_subscriptions (notify_level all/high)
   │     → APNs (time-sensitive for instant/breaking; article payload embedded)
   │     → alerts row (sent → delivered → opened, fully measured)
   ├─ cluster velocity: ≥3 sources / 45min on one cluster ⇒ breaking ⇒ push to topic subscribers
   └─ digest generator (daily, per user digest_hour): Gemini brief → normal-priority push
   ▼
Supabase Postgres: effective_score()/priority_tier() computed at READ — decay needs zero writes
   ▼
SwiftUI app: guest feed (Apple 5.1.1) · Sign in with Apple/Google · List + Immersive views
RevenueCat paywall · PostHog · feed-health admin page + self-alert pushes
```

## 3. Feed fetching, health, and auto-fix (design detail)

**Fetching.** Worker cron every 5 min selects sources where `backoff_until < now()` and `last_fetch_at + poll_interval_s < now()`. Conditional GET (ETag/Last-Modified → 304 = free). `poll_interval_s` adapts: halves (floor 5 min) when a poll finds new items, grows 1.5× (cap 6h) when quiet — busy feeds get polled fast, dead-quiet ones stop wasting requests. Custom topics get Google News RSS query feeds created on subscription, polled on the same loop, feeding the alert matcher (reader cards still prefer curated sources).

**Health states, replacing v2's silent death (20 fails → disabled forever):**

- `ok` → normal polling.
- `degraded` (3+ consecutive failures): exponential backoff (10min → 20 → 40 … cap 6h) — transient outages self-heal, nothing is ever disabled by failure count.
- `broken` (0 successes for 48h): flagged on the admin page **and a push is sent to your phone through NewsFirst's own alert pipeline** (the ops channel is the product, dogfooded).

**Auto-fix ladder, attempted in order before a source is marked broken:**
1. Retry with alternate User-Agent + no conditional headers (fixes 403/stale-ETag cases).
2. Follow permanent redirects and **persist the new feed URL** (fixes moved feeds).
3. Re-discover the feed from the source's homepage `<link rel="alternate">` (fixes restructured sites).
4. Parse tolerantly (encoding sniff, HTML-entity repair) before declaring a parse failure.

**Freshness watchdog** (separate daily check): a source that fetches fine but has produced zero new items for 7 days is flagged `degraded` too — silent-empty is a failure mode HTTP 200 hides. All of this lands in `ingest_runs` + the `sources` health columns (already in the schema), surfaced on a one-page admin dashboard (Cloudflare Pages, phase 2).

## 4. Phases, owners, exit criteria

### Phase 1 — Foundation ✅ (done today, by Claude)
Schema live on the new project (read-time scoring, notify levels, alert funnel, health columns, free-tier trigger enforced server-side) · 58 sources seeded · repo scaffolded (iOS + Worker + migrations) · this plan.

### Phase 2 — Ingest pipeline live (Claude-heavy; needs Tom ~30 min)
Worker deployed on cron: polling, dedupe, enrichment, scoring, inserts; health/backoff/auto-fix; `ingest_runs` populated.
**Tom:** create/connect Cloudflare account, `wrangler login`, set 3 secrets (Supabase service key, Gemini API key — free tier, DB URL). Rotate the DB password you pasted into chat.
**Exit:** articles flowing for 48h, zero manual interventions, admin queries show all sources `ok`/`degraded` with reasons.

### Phase 3 — App core (Claude scaffolds + writes; Tom builds/runs in Xcode)
Xcode project (XcodeGen), guest feed from cache-first store, List + Immersive views hitting the §1 budgets, Sign in with Apple/Google, topic onboarding (topics **before** signup, permission prompt with payoff shown), per-topic notify-level control, PostHog wired.
**Tom:** Apple Developer portal (bundle id, capabilities: push + time-sensitive + NSE), first device run, feel-check on a ProMotion iPhone.
**Exit:** cold start < 400ms on device; 120Hz Instruments trace clean; guest → signup → topics → permission flow complete.

### Phase 4 — The alert loop (the product)
APNs sender in Worker (token auth, payload embeds article), NSE pre-caching, render-from-payload article screen, alert funnel events end-to-end, digest generator, breaking-news velocity promotion.
**Exit:** notification tap → article < 1s cold; `sent → delivered → opened` visible in PostHog for real pushes; quiet hours + daily caps enforced (v2 never enforced them).

### Phase 5 — Monetisation + TestFlight
RevenueCat, paywall (trial), plan-gating (server trigger already enforces 3 custom topics), TestFlight to the 44 known v2 emails + niche communities.
**Exit:** activation (topics+push) and trial-start rates measurable against the strategy's kill gates (activation ≥25%, trial ≥4% of activated).

### Phase 6 — Launch + acquisition test (£200–250)
App Store listing (guest mode satisfies 5.1.1), Apple Search Ads on alert-intent keywords, share cards.
**Exit:** CPI → activation → trial → paid chain measured; continue/reposition decision per the strategy gates.

## 5. What I can do without you vs what only you can do

| Claude (autonomous) | Tom (account owner, ~2h total across phases) |
|---|---|
| All schema/migrations, seeds, SQL functions | Rotate DB password; add service key to Worker secrets |
| All Worker code + tests; deploy once wrangler is authed | Cloudflare account + `wrangler login` (once) |
| All Swift/SwiftUI code, project config, design system | Xcode installed, Apple Developer: bundle id, push key, entitlements |
| PostHog dashboards/insights; owner-cohort fix | App Store Connect app record, TestFlight, review submissions |
| Admin dashboard page | RevenueCat account + App Store Connect API key |
| Landing-page copy updates | Gemini API key (free); DNS if landing page moves |

## 6. Risks specific to this plan

1. **Solo native stack**: no OTA updates — mitigated by TestFlight-first releases and the InjectionIII/Previews loop for development speed; App Review is ~24h for fixes.
2. **APNs from a Worker**: token-based APNs over HTTP/2 from Cloudflare Workers is proven but fiddly (p8 key handling) — fallback is a tiny push relay or OneSignal free tier without changing the schema.
3. **Google News query feeds are unofficial** — used for alert matching only; curated feeds remain the reader backbone; per-source RSS is the Pro upgrade path.
4. **Free-tier ceilings** (Supabase 500MB, Gemini 1,500 req/day): both are ~10× headroom at current volume; paid fallbacks ≤£25/mo named in the strategy.
