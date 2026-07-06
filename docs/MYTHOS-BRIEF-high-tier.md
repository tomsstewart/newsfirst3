# MYTHOS BRIEF — High-tier over-population (first diagnosis + fix spec)

**Author:** Claude (Opus 4.8), 2026-07-06 · **Project:** NewsFirst v3
**DB:** `sbqdvtzsezxupxxbmjsb` (prod) · **Repo HEAD:** `f0f46bd`, build 26 (2.0.0), working tree clean & pushed
**Purpose:** You're low on credits — this is meant to be complete enough that you can **sense-check and integrate without re-exploring**. Every claim below was verified against live prod data (queries at the end). Push back on anything that looks wrong.

---

## TL;DR — the one thing

A **server regression** is the cause. Migration `0024_soft_breaking_bar.sql` (5 Jul 20:54) gated soft-topic stories out of the breaking/High band unless 5+ sources corroborated. Migration `0027_per_topic_tiers.sql` (6 Jul 09:54) did `create or replace view public.feed` again for the per-topic Medium work and **did not carry the gate forward**, silently reverting 0024. Since migrations apply in filename order, **0027's gate-less view is what's live.**

**Fix = one new migration `0028` that re-applies 0024's `breaking_eff` gate on top of 0027's per-topic `tier_of`.** Build-independent, fixes every pane + the bell inbox. Full SQL below.

Everything else (cluster flooding, client soft-cap) is either **already handled in-app** or **secondary**. Do not redo work that exists.

---

## How "High" is defined (sense-check this against the source)

1. **`tier_of()`** (`supabase/migrations/0027_per_topic_tiers.sql:69-81`): an article is `high` **iff** `breaking AND published_at > now() - 6h`. Score/percentile can only ever produce **`medium`**. So "too many High" ≡ "too many clusters flagged breaking."
2. **`is_breaking`** is set in **`assign_clusters()`** (`0026_syndication_groups.sql:74-81`): a cluster is breaking when **≥3 distinct sources** publish within **45 min** of first sighting. 0026 made this **syndication-aware** — Reach papers (MEN/Liverpool Echo/WalesOnline) count as one source (`coalesce(syndication_group, source_id)`), which correctly killed fake breaking clusters. That fix is fine; leave it.
3. **The gate that regressed** — `feed.breaking_eff` in `0024_soft_breaking_bar.sql:10-13`:
   ```
   coalesce(c.is_breaking,false)
     and published_at > now() - 6h
     and ( not (topics && array['sports','entertainment','gaming','travel'])
           or coalesce(c.source_count,1) >= 5 )
   ```
   0024 fed `breaking_eff` into the tier, the +25 boost **and** the exposed `breaking` column. **0027's view uses raw `coalesce(c.is_breaking,false)` instead** — the gate is gone.

---

## Live evidence (prod, pulled 2026-07-06 ~17:45 UTC)

- **82 articles** currently `tier='high'`, spanning **24 distinct clusters**.
- **47 / 82 (57%)** carry a soft tag (`sports`/`entertainment`/`gaming`/`travel`) — FIFA/World Cup, Xbox layoffs, celebrity, crypto.
- **3 are strictly soft AND <5 sources** (Ricky Gervais/The Office 3-src, 2 Chainz 3-src, Angel Reese WNBA 3-src). **These are the smoking gun**: under 0024's gate they'd be excluded from High. They're live → the gate is off → confirms 0027 reverted 0024. (On a normal news day this leaks far more; today just happens to be dominated by genuinely multi-source stories.)
- The Xbox-layoffs event appears as **two separate clusters** (leads "Here's What's Going On With Marvel's Blade…" and "Xbox is laying off 3,200 people…", both 13-src) → server-side **under-merging**, not a client dedup gap (see below).

Tom's subjective read ("60–70% miscategorised as High") is fair: sports results, gaming layoffs, crypto treasury moves and celebrity items clear the mechanical 3-source bar but don't feel like front-page breaking news.

---

## Root causes, ranked

### 1. PRIMARY — server, build-independent: 0027 clobbered 0024's soft-breaking bar
The `feed` view lost `breaking_eff`. **Fixes everything downstream at once**: Top Stories, the Sports/Entertainment/Gaming panes (which currently show inflated High), and the **bell inbox** (`FeedStore.swift:550 breakingStories = collapseDuplicates(articles.filter { tier == .high })` — driven straight off server tier; no client mitigation touches it). **→ Migration 0028 below.**

### 2. SECONDARY — server: low corroboration bar + cluster under-merge
Even with the gate restored, "3 sources in 45 min" is a low bar, and `assign_clusters()` under-merges (one real event → 2+ clusters, e.g. the two Xbox clusters), so a single big story still yields multiple High cards. Options, in order of preference:
- **Widen cluster merge** — the embedding distance threshold is `< 0.15` (`0026:32`) and title-similarity `> 0.5` (`0026:44`); loosening slightly would merge the two Xbox clusters. Risk: over-merging distinct stories. Test before/after.
- **Or** raise the breaking bar to 4 sources for *all* topics (soft already needs 5).
- **Or** a hard cap on simultaneous High per refresh window.
Recommend: ship #1 (fix #0028) first, observe, then decide if #2 is even needed. Don't over-engineer.

### 3. CLIENT — mostly already handled; do NOT duplicate
- **Per-cluster flooding is already solved in-app.** `FeedStore.swift:444` → `collapseDuplicates()` (`:450-473`) keeps one telling per `clusterID` (title-prefix fallback, prefers an image-bearing telling). Landed in `d397d1a`. So the phone does **not** render 30 Xbox rows — it renders ~2 (the two under-merged clusters). **Do not add client dedup.** The residual dup is server-side clustering (root cause #2).
- **`frontPageSoftCap`** (`FeedStore.swift:382-391`, used at `:423`) demotes purely-soft breaking to Medium **on Top Stories only**. Two limits: (a) it ships in **build 26, which is NOT uploaded** (TestFlight on hold — do not upload without Tom's explicit OK); (b) it only fires when `Set(topics).isSubset(softTopics)` — so **mixed tags escape it** (FIFA tagged `world,sports`; Xbox tagged `business,gaming`/`tech,gaming`) and so does **mis-tagged content** (the Taylor Swift wedding is tagged `world`). Once #0028 lands server-side, `frontPageSoftCap` becomes redundant belt-and-suspenders. **Recommendation: rely on the server fix; leave `frontPageSoftCap` as-is, don't expand it.**
- There's also a `frontPage` ranking nudge (`rankAdjust`, `:196-223`: hard topics +6, pure-soft −6) — orthogonal, leave it.

---

## The fix — new migration `0028_restore_soft_breaking_bar.sql`

Re-applies 0024's `breaking_eff` gate but keeps **0027's 4-arg `tier_of(...,topics)`** so the per-topic Medium band survives. Same column list/names as 0027 (client reads by name via PostgREST — must not change).

```sql
-- 0028_restore_soft_breaking_bar.sql
-- REGRESSION FIX: 0027_per_topic_tiers redefined public.feed for the per-topic
-- Medium band and dropped the soft-breaking gate that 0024_soft_breaking_bar
-- added, so every 3-source soft cluster (sports/entertainment/gaming/travel)
-- is High again and floods the bell inbox. This restores the gate ON TOP OF
-- 0027 — the per-topic tier_of overload and Medium band are untouched; only
-- breaking_eff (the gated flag) drives High, the +25 boost, and the exposed
-- breaking column, exactly as 0024 intended, using 0027's 4-arg tier_of.

create or replace view public.feed with (security_invoker = true) as
  with base as (
    select a.id, a.url, a.title, a.excerpt, a.image_url, a.image_status,
           a.published_at, a.topics, a.regions, a.cluster_id, a.base_score, a.fts,
           s.name as source_name, s.home_url as source_home,
           coalesce(c.source_count, 1) as cluster_sources,
           ( coalesce(c.is_breaking, false)
             and a.published_at > now() - interval '6 hours'
             and ( not (a.topics && array['sports','entertainment','gaming','travel'])
                   or coalesce(c.source_count, 1) >= 5 ) ) as breaking_eff
    from public.articles a
    join public.sources s on s.id = a.source_id
    left join public.clusters c on c.cluster_id = a.cluster_id
    where a.published_at > now() - interval '30 days'
  )
  select id, url, title, excerpt, image_url, image_status, published_at,
         topics, regions, cluster_id, source_name, source_home,
         (public.effective_score(base_score, published_at)
            + case when breaking_eff then 25 else 0 end) as score,
         public.tier_of(
            public.effective_score(base_score, published_at)
              + case when breaking_eff then 25 else 0 end,
            breaking_eff,
            published_at,
            topics) as tier,
         breaking_eff as breaking,
         fts,
         cluster_sources
  from base;
```

**Deploy:** the Supabase CLI is already linked to `sbqdvtzsezxupxxbmjsb` (`supabase/.temp/linked-project.json`), so `supabase db push` applies it. (Claude's Supabase MCP is currently authed to a *different* account — token 403s on this project — so MCP-based apply isn't available until Tom swaps in a PAT from the `tshawstewart@gmail.com` account, which he's opted to make read-write.)

---

## Sense-check checklist (cheap — do these before applying)

- [ ] **Signatures exist:** `public.tier_of(numeric, boolean, timestamptz, text[])` and `public.effective_score(numeric, timestamptz)` — both defined in 0027 / 0014. `tier_of` here passes `breaking_eff` (gated) as arg 2 and `topics` as arg 4.
- [ ] **No later migration restores the gate:** `0027` is the last migration; nothing after it. Working tree clean. Confirmed.
- [ ] **Columns unchanged vs 0027:** id,url,title,excerpt,image_url,image_status,published_at,topics,regions,cluster_id,source_name,source_home,score,tier,breaking,fts,cluster_sources. Client selects a subset by name (`SupabaseAPI.swift:11`) — safe.
- [ ] **`security_invoker = true`** preserved (RLS/anon reads depend on it — the "0014 gotcha").
- [ ] **No retro-pass needed:** `feed` is a view; it recomputes on read. (0024/0026's one-off `update clusters` retro-clears already ran; is_breaking data is fine — we're only re-gating the *presentation*.)
- [ ] **Topic list intentional:** `{sports,entertainment,gaming,travel}`. Note `gaming` includes the Xbox layoffs (13-src) — the `>=5` branch keeps genuinely-big gaming stories High, so this is correct, not a regression.

## Do NOT

- Don't edit 0027 (or 0024) in place — migrations are append-only and already applied. Add 0028.
- Don't touch `tier_of` / `refresh_tier_thresholds` / `tier_thresholds_topic` — the per-topic Medium work is good; only the *view* lost the gate.
- Don't add client-side cluster dedup — `collapseDuplicates` already does it.
- Don't upload a TestFlight build without Tom's explicit OK.

## Open items (need Tom)

1. **Installed TestFlight build unknown.** The server fix is build-independent (priority). Client behaviour (frontPageSoftCap) only exists in build 26, unshipped — confirm what's actually on the phone before reasoning about client-side symptoms.
2. **Decide on root cause #2** (cluster merge / bar) only after observing #0028 in prod.
3. **Migration-number hygiene:** there are already duplicate numbers on disk (two each of 0024/0025/0026) from parallel work. `0028` is free and unambiguous; just be aware ordering is lexical by full filename.

---

## Re-verify the diagnosis yourself (no model tokens — pure REST)

Publishable/anon key is shippable (RLS is the boundary). Run:

```bash
KEY="sb_publishable_zakPOvvP-fVhODt3_hVesA_AIDDGwV7"
BASE="https://sbqdvtzsezxupxxbmjsb.supabase.co/rest/v1/feed"
# Soft-topic, <5-source articles currently in High (should be 0 after 0028):
curl -s "$BASE?tier=eq.high&select=title,topics,cluster_sources,source_name&order=cluster_sources.asc" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
 | python3 -c "import sys,json;S={'sports','entertainment','gaming','travel'};d=json.load(sys.stdin);v=[a for a in d if set(a['topics'])&S and a['cluster_sources']<5];print('soft<5 in High:',len(v));[print(' ',a['cluster_sources'],a['topics'],a['title'][:70]) for a in v]"
```
Before 0028: prints the soft <5 offenders. After 0028: should print `0`.
