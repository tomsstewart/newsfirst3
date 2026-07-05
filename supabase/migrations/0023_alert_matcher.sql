-- Alert matcher: the SQL half of push. claim_alerts() finds fresh articles that match
-- subscriptions, applies every quality gate (dedupe, cluster cool-down, quiet hours,
-- daily cap, per-run cap), INSERTS the alerts rows (the insert IS the claim — two
-- overlapping runs can't double-send), and returns each claimed alert with the user's
-- device tokens for the edge function to fan out to APNs.
--
-- notify_level semantics (0021 made these literal):
--   'high' -> only tier 'high' = breaking (3+ sources / 45 min, < 6h old)
--   'all'  -> every match; daily_cap (default 30) is the firehose guard
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
  -- Alert on discovery (first_seen_at), not published_at: feeds backfill old pieces.
  -- published_at guard keeps a stale-but-just-discovered article from paging anyone.
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
  -- One alert per (user, story): a multi-article cluster collapses to its best row.
  select distinct on (ts.user_id, coalesce(f.cluster_id, f.id))
         ts.user_id, f.id as article_id, ts.topic,
         case when f.tier = 'high' then 'breaking' else 'instant' end as kind,
         f.title, f.excerpt, f.source_name, f.cluster_id
  from topic_subscriptions ts
  join fresh f on (
        (ts.kind = 'preset' and ts.topic = any(f.topics))
     or (ts.kind = 'custom' and f.fts @@ websearch_to_tsquery('english', ts.topic)))
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
    -- cluster cool-down: one push per story per 6h, however many follow-ups land
    and (m.cluster_id is null or not exists (
          select 1 from alerts al
          join articles a2 on a2.id = al.article_id
          where al.user_id = m.user_id
            and a2.cluster_id = m.cluster_id
            and al.sent_at > now() - interval '6 hours'))
    -- quiet hours, evaluated in the user's own timezone (wraparound-safe)
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
    -- rolling 24h cap (default 30); per-run cap below bounds the race window
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

-- Service role only: cron -> edge function -> rpc. Never the app.
revoke all on function public.claim_alerts() from public, anon, authenticated;
grant execute on function public.claim_alerts() to service_role;

-- 2 minutes after each ingest tick (:00/:05/...), so fresh articles are clustered first.
select cron.schedule('alerts_tick', '2-59/5 * * * *', $$select public.invoke_ingest('alerts')$$);
