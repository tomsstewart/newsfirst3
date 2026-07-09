-- 0032_high_gate_and_dedup.sql
-- Two fixes, both live-verified against prod on 2026-07-09.
--
-- (1) HIGH-TIER FLOOD. importance (Gemini 0-3) covers only ~23% of High candidates
--     because the free-tier quota (20/day) can't rate ~5000 articles/day and the
--     hourly backfill was timing out. When importance is null, 0029's fallback only
--     gated the 4 soft topics by source-count, so any world/business/tech/health
--     cluster with 3+ sources flooded High (157 live: Wimbledon results, golf
--     leaderboards, "how to watch", Taylor Swift wedding cost, a £34 dress...).
--     Also Gemini rates sports results / BTS songs as importance=2, so even the
--     rated path leaked soft results into High.
--
--     New high_eff (title-aware):
--       published < 6h AND (
--            importance >= 3                                   -- front-page, ANY topic/source
--         or (breaking AND importance = 2 AND not soft)        -- corroborated hard news
--         or (importance IS NULL AND breaking AND hardnews     -- unrated: narrow recent
--             AND not soft AND not fluff-headline              -- breaking-hardnews window
--             AND published < 2h AND sources >= 6) )           -- (the enrichment lag)
--     Soft topics (sports/entertainment/gaming/travel) now need importance>=3 for High.
--     Everything else unrated & older than 2h drops to Medium until Gemini rates it.
--     Dry-run: 157 -> 40, every survivor legitimate hard news.
--
-- (2) ALERT SPAM / DUPLICATES. Tom's rule: 'all' subs get everything EXCEPT clear
--     duplicates on a topic; 'high-only' is fixed for free by (1). The trigram(>0.55)
--     title guard missed same-story alerts with different headlines (MARA x3, BitGo x2
--     — all embedding-distance <=0.067; distinct bitcoin stories start at 0.093). Add
--     an embedding-distance guard (< 0.08 vs the user's own alerts in the last 24h).
--     NO per-topic cap (Tom: 'all' must mean all-minus-dupes).

-- ---------- (1) fluff-headline heuristic + title-aware high_eff ----------

-- Cheap, no-LLM demotion of match-reports / betting / listicles / shopping filler.
-- Only consulted for UNRATED items in the narrow recent-breaking window; Gemini's
-- importance rating overrides it in both directions once it lands.
create or replace function public.is_fluff_headline(title text)
returns boolean language sql immutable as $$
  select coalesce(title,'') ~* (
    '(\yodds\y|\yprediction\y|\ypreview\y|how to watch|where to watch|live stream'
    '|\yleaderboard\y|\yhighlights\y|line-?ups?|kick-?off|\yfantasy\y|\yrankings?\y'
    '|walkthrough|\yrecap\y|round-?up|best bet|team news|order of play|\yh2h\y'
    '|tv channel|\yvs\.?\y|tie-?break|essential .*songs|where to buy'
    '|\y\d+ (best|things|ways|takeaways|reasons)\y|\ycompliments\y|\yflattering\y)'
  )
$$;
revoke execute on function public.is_fluff_headline(text) from public;
grant execute on function public.is_fluff_headline(text) to anon, authenticated, service_role;

-- Title-aware High gate. Supersedes 0029's 5-arg high_eff.
create or replace function public.high_eff(
  breaking boolean, published timestamptz, topics text[],
  sources integer, importance smallint, title text
) returns boolean
language sql stable
as $$
  select published > now() - interval '6 hours'
     and (
          coalesce(importance, 0) >= 3
       or ( coalesce(breaking, false) and importance = 2
            and not (topics && array['sports','entertainment','gaming','travel']) )
       or ( importance is null and coalesce(breaking, false)
            and (topics && array['world','business','politics','economics','science','health','climate'])
            and not (topics && array['sports','entertainment','gaming','travel'])
            and not public.is_fluff_headline(title)
            and published > now() - interval '2 hours'
            and coalesce(sources, 1) >= 6 )
     )
$$;
revoke execute on function public.high_eff(boolean, timestamptz, text[], integer, smallint, text) from public;
grant execute on function public.high_eff(boolean, timestamptz, text[], integer, smallint, text) to anon, authenticated, service_role;

-- feed view: call the title-aware gate (otherwise identical to 0029).
create or replace view public.feed with (security_invoker = true) as
  with base as (
    select a.id, a.url, a.title, a.excerpt, a.image_url, a.image_status,
           a.published_at, a.topics, a.regions, a.cluster_id, a.base_score, a.fts,
           s.name as source_name, s.home_url as source_home,
           coalesce(c.source_count, 1) as cluster_sources,
           public.high_eff(c.is_breaking, a.published_at, a.topics,
                           coalesce(c.source_count, 1), a.importance, a.title) as breaking_eff
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

-- ---------- (2) claim_alerts: title-aware gate + embedding dedup ----------
create or replace function public.claim_alerts()
returns table (
  alert_id    uuid,
  user_id     uuid,
  article_id  uuid,
  topic       text,
  kind        text,
  title       text,
  excerpt     text,
  source_name text,
  cluster_id  uuid,
  devices     jsonb
)
language sql security definer set search_path = public
as $$
with fresh as (
  select a.id, a.title, a.excerpt, a.topics, a.fts, a.cluster_id, a.published_at,
         s.name as source_name,
         public.tier_of(
           public.effective_score(a.base_score, a.published_at)
             + case when public.high_eff(c.is_breaking, a.published_at, a.topics,
                                         coalesce(c.source_count, 1), a.importance, a.title)
                    then 25 else 0 end,
           public.high_eff(c.is_breaking, a.published_at, a.topics,
                           coalesce(c.source_count, 1), a.importance, a.title),
           a.published_at) as tier
  from articles a
  join sources s on s.id = a.source_id
  left join clusters c on c.cluster_id = a.cluster_id
  where a.first_seen_at > now() - interval '30 minutes'
    and a.published_at  > now() - interval '24 hours'
),
matches as (
  select distinct on (ts.user_id, coalesce(f.cluster_id, f.id))
         ts.user_id, f.id as article_id, ts.topic,
         case when f.tier = 'high' then 'breaking' else 'instant' end as kind,
         f.title, f.excerpt, f.source_name, f.cluster_id
  from topic_subscriptions ts
  join fresh f on (
        (ts.kind = 'preset' and ts.topic = any(f.topics))
     or (ts.kind = 'custom' and f.fts @@ websearch_to_tsquery('english', ts.topic)
         and public.matches_keyword(f.title, f.excerpt, ts.topic)))
  where ts.notify_level = 'all'
     or (ts.notify_level = 'high' and f.tier = 'high')
  order by ts.user_id, coalesce(f.cluster_id, f.id),
           (f.tier = 'high') desc, f.published_at desc
),
eligible as (
  select m.*
  from matches m
  left join notification_settings ns on ns.user_id = m.user_id
  where exists (select 1 from devices d where d.user_id = m.user_id and d.is_valid)
    and not exists (select 1 from alerts al
                    where al.user_id = m.user_id and al.article_id = m.article_id)
    -- cluster cool-down: one push per story per 6h
    and (m.cluster_id is null or not exists (
          select 1 from alerts al
          join articles a2 on a2.id = al.article_id
          where al.user_id = m.user_id
            and a2.cluster_id = m.cluster_id
            and al.sent_at > now() - interval '6 hours'))
    -- CROSS-CLUSTER duplicate guard (title trigram): same story fragmented into two
    -- clusters still reads as one story to a human.
    and not exists (
          select 1 from alerts al
          join articles a3 on a3.id = al.article_id
          where al.user_id = m.user_id
            and al.sent_at > now() - interval '12 hours'
            and similarity(a3.title, m.title) > 0.55)
    -- SEMANTIC duplicate guard (0032): the trigram check misses same-story alerts
    -- with reworded headlines (MARA x3, BitGo x2). Embedding distance < 0.08 = clear
    -- duplicate (distinct same-topic stories start at 0.093). This is what makes
    -- 'all' mean "all, minus clear duplicates" without a per-topic cap.
    and not exists (
          select 1 from alerts al
          join articles a4 on a4.id = al.article_id
          join articles ac on ac.id = m.article_id
          where al.user_id = m.user_id
            and al.sent_at > now() - interval '24 hours'
            and a4.embedding is not null and ac.embedding is not null
            and (a4.embedding <=> ac.embedding) < 0.08)
    -- quiet hours in the user's timezone (wraparound-safe)
    and not coalesce(
          ns.quiet_start is not null and ns.quiet_end is not null and (
            case when ns.quiet_start <= ns.quiet_end
              then (extract(hour   from now() at time zone coalesce(ns.tz, 'UTC'))::int * 60
                  + extract(minute from now() at time zone coalesce(ns.tz, 'UTC'))::int)
                   between ns.quiet_start and ns.quiet_end
              else (extract(hour   from now() at time zone coalesce(ns.tz, 'UTC'))::int * 60
                  + extract(minute from now() at time zone coalesce(ns.tz, 'UTC'))::int) >= ns.quiet_start
                or (extract(hour   from now() at time zone coalesce(ns.tz, 'UTC'))::int * 60
                  + extract(minute from now() at time zone coalesce(ns.tz, 'UTC'))::int) <= ns.quiet_end
            end), false)
    and (select count(*) from alerts al
         where al.user_id = m.user_id and al.sent_at > now() - interval '24 hours')
        < coalesce(ns.daily_cap, 30)
),
capped as (
  select e.*, row_number() over (
           partition by e.user_id
           order by (e.kind = 'breaking') desc) as rn
  from eligible e
),
claimed as (
  insert into alerts (user_id, article_id, topic, kind)
  select c.user_id, c.article_id, c.topic, c.kind
  from capped c where c.rn <= 3
  returning id, user_id, article_id, topic, kind
)
select cl.id, cl.user_id, cl.article_id, cl.topic, cl.kind,
       c2.title, c2.excerpt, c2.source_name, c2.cluster_id,
       (select jsonb_agg(jsonb_build_object('token', d.apns_token, 'environment', d.environment))
        from devices d
        where d.user_id = cl.user_id and d.is_valid)
from claimed cl
join capped c2 on c2.user_id = cl.user_id and c2.article_id = cl.article_id;
$$;

revoke all on function public.claim_alerts() from public, anon, authenticated;
grant execute on function public.claim_alerts() to service_role;

-- Retire 0029's 5-arg gate now that both callers use the title-aware version.
drop function if exists public.high_eff(boolean, timestamptz, text[], integer, smallint);
