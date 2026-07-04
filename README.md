# NewsFirst v3

Alerts-first personal news radar. iPhone-native (SwiftUI), Supabase backend, Cloudflare Worker ingestion.
Strategy: `../NewsFirst v3 Strategy.md` · Plan: `docs/DELIVERY_PLAN.md`.

## Layout

```
supabase/migrations/   schema + cron (applied to project sbqdvtzsezxupxxbmjsb)
supabase/functions/    ingest edge function: RSS polling, enrichment, scoring, health
ios/                   SwiftUI app (XcodeGen project)
admin/                 feed-health dashboard (phase 2)
docs/                  delivery plan
```

## Core invariants (do not break)

1. **Scoring is write-once.** `articles.base_score` is set at ingest and never updated. Decay/tier are computed at read time by `effective_score()` / `priority_tier()` (see `feed` view). No job may UPDATE scores.
2. **Speed budgets are acceptance criteria**: cold start < 400ms, notification→article < 1s, 120Hz scroll. See `docs/DELIVERY_PLAN.md` §1.
3. **No source is ever silently disabled.** Failures → backoff (`degraded`) → `broken` + owner alert. Auto-fix ladder in `ingest/src/index.ts`.
4. **Secrets never in the repo.** Service key/Gemini key live in Worker secrets; the iOS app ships only the publishable key (RLS is the boundary).
5. Per-topic `notify_level` (`none`/`high`/`all`) is enforced server-side by the alert matcher, not just UI.

## Setup

### Backend (done)
Migrations 0001–0003 are applied; 58 sources seeded.

### Ingest edge function (no Cloudflare — everything runs on Supabase)
```
supabase login                                    # one-time, opens browser
supabase link --project-ref sbqdvtzsezxupxxbmjsb
supabase secrets set GEMINI_API_KEY=<key from aistudio.google.com>
supabase functions deploy ingest
```
Then one SQL statement in the Dashboard SQL editor to arm the (already-scheduled) cron jobs:
```sql
select vault.create_secret('<service-role-key from Settings → API>', 'service_role_key');
```
pg_cron then invokes the function every 5 min (ingest), hourly (health watchdog), and daily (90-day purge).
The key lives in Vault — never plaintext in cron commands (v2's mistake).

### iOS
```
brew install xcodegen
cd ios && xcodegen generate && open NewsFirst.xcodeproj
```
Hot reload: run the [InjectionIII](https://github.com/johnno1962/InjectionIII) app, build to simulator, edit any view — it live-updates (`Inject` package + `-interposable` are already configured). SwiftUI Previews work per-view out of the box.
