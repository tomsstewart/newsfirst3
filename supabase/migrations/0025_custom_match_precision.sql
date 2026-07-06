-- Custom-topic match precision (found via the 2026-07-06 alert audit):
--   1. STEMMING FALSE POSITIVES: websearch('boxing') stems to 'box' and matched
--      "China Box Office" + a Boots perfume ad. FTS keeps recall; a literal
--      word-boundary check on title+excerpt restores precision. Only applied for
--      plain alphanumeric keywords — anything fancier keeps pure FTS.
--   2. DUPLICATE-STORY ALERTS: the same story from two sources landed in two
--      clusters ("Trump thanks FIFA", sent twice in 3h) — a trigram similarity
--      guard against the user's recent alert titles catches what clustering misses.

-- Shared literal check (immutable so both the RPC and matcher can inline it).
create or replace function public.matches_keyword(title text, excerpt text, q text)
returns boolean language sql immutable as $$
  select case
    when q ~ '^[a-zA-Z0-9 ]+$'
      then (coalesce(title,'') || ' ' || coalesce(excerpt,'')) ~* ('\y' || q || '\y')
    else true   -- quoted phrases / operators: trust websearch semantics
  end
$$;

-- Search RPC: same FTS recall, literal precision, unchanged ranking.
create or replace function public.search_feed(q text)
returns setof public.feed
language sql stable
as $$
  select f.*
  from public.feed f
  where f.fts @@ websearch_to_tsquery('english', q)
    and public.matches_keyword(f.title, f.excerpt, q)
  order by ts_rank(f.fts, websearch_to_tsquery('english', q))
           * exp(-extract(epoch from now() - f.published_at) / (36.0 * 3600))
           desc
  limit 80
$$;

-- Matcher: precision filter on custom subs + cross-cluster duplicate guard.
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
             + case when c.is_breaking and a.published_at > now() - interval '6 hours' then 25 else 0 end,
           coalesce(c.is_breaking, false), a.published_at) as tier
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
    -- CROSS-CLUSTER duplicate guard: same story fragmented into two clusters
    -- still reads as one story to a human — trigram similarity vs recent alerts.
    and not exists (
          select 1 from alerts al
          join articles a3 on a3.id = al.article_id
          where al.user_id = m.user_id
            and al.sent_at > now() - interval '12 hours'
            and similarity(a3.title, m.title) > 0.55)
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
revoke all on function public.matches_keyword(text, text, text) from public;
grant execute on function public.matches_keyword(text, text, text) to service_role, anon, authenticated;
