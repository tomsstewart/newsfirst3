-- 0034_importance_tiers_and_inbox.sql
-- Tom, 2026-07-09: High/Medium must be GENUINELY selective, not a hard-capped slice of
-- a loose tier. Model it on how Apple News / Google surface breaking news — significance
-- × corroboration × recency, sparse by design:
--   HIGH   = importance 3 (Gemini "drop-everything major") AND < 6h.  (~0-3/day normal;
--            more only on a genuine mega-news day. This is also the push bar.)
--   MEDIUM = importance 2 (significant hard news) AND corroborated (is_breaking, 3+ distinct
--            sources / 45 min) AND < 6h.  importance=2 ALONE is ~564/day — far too loose;
--            requiring corroboration + recency cuts it to ~0-2 per topic.
--   LOW    = everything else (the routine bulk; still ranked by score).
-- No hard display cap — the criteria do the work. Unrated items sit in Low until Gemini
-- rates them (enrichment promotes the real ones), which is the picky-by-default behaviour.

create or replace function public.article_tier(
  importance smallint, is_breaking boolean, published timestamptz
) returns text
language sql stable
as $$
  select case
    when published > now() - interval '6 hours' and importance = 3 then 'high'
    when published > now() - interval '6 hours' and importance = 2 and coalesce(is_breaking, false) then 'medium'
    else 'low'
  end
$$;
revoke execute on function public.article_tier(smallint, boolean, timestamptz) from public;
grant execute on function public.article_tier(smallint, boolean, timestamptz) to anon, authenticated, service_role;

-- feed view: importance-driven tier. Score still drives ranking (high/medium get a boost
-- so they sit at the top of their pane); tier is now the article_tier verdict.
create or replace view public.feed with (security_invoker = true) as
  with base as (
    select a.id, a.url, a.title, a.excerpt, a.image_url, a.image_status,
           a.published_at, a.topics, a.regions, a.cluster_id, a.base_score, a.fts,
           s.name as source_name, s.home_url as source_home,
           coalesce(c.source_count, 1) as cluster_sources,
           public.article_tier(a.importance, c.is_breaking, a.published_at) as tier_v
    from public.articles a
    join public.sources s on s.id = a.source_id
    left join public.clusters c on c.cluster_id = a.cluster_id
    where a.published_at > now() - interval '30 days'
  )
  select id, url, title, excerpt, image_url, image_status, published_at,
         topics, regions, cluster_id, source_name, source_home,
         (public.effective_score(base_score, published_at)
            + case tier_v when 'high' then 25 when 'medium' then 10 else 0 end) as score,
         tier_v as tier,
         (tier_v = 'high') as breaking,
         fts,
         cluster_sources
  from base;

-- claim_alerts: notification "high" == article_tier high (importance 3). A high-only or
-- Top Stories ('top') subscription now fires only on genuinely major stories — sparse,
-- Apple-News-style. 'all' custom subs still match every (deduped) article.
create or replace function public.claim_alerts()
returns table (
  alert_id    uuid, user_id uuid, article_id uuid, topic text, kind text,
  title text, excerpt text, source_name text, cluster_id uuid, devices jsonb
)
language sql security definer set search_path = public
as $$
with fresh as (
  select a.id, a.title, a.excerpt, a.topics, a.fts, a.cluster_id, a.published_at,
         s.name as source_name,
         public.article_tier(a.importance, c.is_breaking, a.published_at) as tier
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
        (ts.kind = 'preset' and ts.topic = 'top' and f.tier = 'high')
     or (ts.kind = 'preset' and ts.topic <> 'top' and ts.topic = any(f.topics))
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
    and (m.cluster_id is null or not exists (
          select 1 from alerts al
          join articles a2 on a2.id = al.article_id
          where al.user_id = m.user_id
            and a2.cluster_id = m.cluster_id
            and al.sent_at > now() - interval '6 hours'))
    and not exists (
          select 1 from alerts al
          join articles a3 on a3.id = al.article_id
          where al.user_id = m.user_id
            and al.sent_at > now() - interval '12 hours'
            and similarity(a3.title, m.title) > 0.55)
    and not exists (
          select 1 from alerts al
          join articles a4 on a4.id = al.article_id
          join articles ac on ac.id = m.article_id
          where al.user_id = m.user_id
            and al.sent_at > now() - interval '24 hours'
            and a4.embedding is not null and ac.embedding is not null
            and (a4.embedding <=> ac.embedding) < 0.08)
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
  select e.*, row_number() over (partition by e.user_id order by (e.kind = 'breaking') desc) as rn
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
        from devices d where d.user_id = cl.user_id and d.is_valid)
from claimed cl
join capped c2 on c2.user_id = cl.user_id and c2.article_id = cl.article_id;
$$;
revoke all on function public.claim_alerts() from public, anon, authenticated;
grant execute on function public.claim_alerts() to service_role;

-- Notification inbox: ONLY articles that actually pushed to THIS user (the bell drawer
-- was showing every high-tier story, not the user's push history). security_invoker so
-- the alerts RLS (own rows) scopes it; shaped like `feed` so the client reuses Article.
-- Briefs (article_id null) are excluded — the drawer is article notifications.
create or replace view public.alert_inbox with (security_invoker = true) as
  select al.id as alert_id, al.sent_at, al.kind as alert_kind, al.topic as alert_topic,
         a.id, a.url, a.title, a.excerpt, a.image_url, a.image_status, a.published_at,
         a.topics, a.regions, a.cluster_id, s.name as source_name, s.home_url as source_home,
         public.effective_score(a.base_score, a.published_at) as score,
         public.article_tier(a.importance, c.is_breaking, a.published_at) as tier,
         (public.article_tier(a.importance, c.is_breaking, a.published_at) = 'high') as breaking,
         a.fts, coalesce(c.source_count, 1) as cluster_sources
  from public.alerts al
  join public.articles a on a.id = al.article_id
  join public.sources s on s.id = a.source_id
  left join public.clusters c on c.cluster_id = a.cluster_id;
grant select on public.alert_inbox to authenticated;
