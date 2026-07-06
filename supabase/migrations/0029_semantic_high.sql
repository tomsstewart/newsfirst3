-- 0029_semantic_high.sql
-- High tier goes semantic (Tom, 2026-07-06): source-count alone is the wrong
-- breaking signal in BOTH directions — "Met Office gives verdict" / "Paolini fends
-- off Eala" / "Will Balogun play?" clear the 3-source bar but are routine, while a
-- genuine mega-story can surface with ONE source. The Gemini enrichment batch now
-- also rates each headline's front-page importance 0-3 (articles.importance, edge
-- function change, zero extra quota — same single call). The High gate becomes:
--
--   high_eff = published < 6h AND (
--        importance >= 3                                  -- truly breaking, ANY source count
--     or ( is_breaking AND ( importance >= 2              -- corroborated AND actually significant
--          or (importance IS NULL AND 0028's soft-topic gate) ) ) )  -- unrated (≤2h lag): old behaviour
--
-- Rated importance<=1 (sports results/previews, celebrity, weather chatter, opinion)
-- can NEVER be High regardless of sources. Same gate is applied to claim_alerts,
-- which computed tier from raw is_breaking and was never covered by 0024's gate.
--
-- Also: entity-aware cluster merging. assign_clusters runs minutes after ingest but
-- entities arrive with enrichment (~2h later), so multi-angle events split into
-- sibling clusters ("Marvel's Blade cancelled" vs "Xbox lays off 3,200") that the
-- strict d<0.12 retro-merge never rejoins. merge_clusters gains a second pass:
-- clusters sharing >=2 entities within d<0.32 merge — everything-Xbox becomes one card.

alter table public.articles add column if not exists importance smallint;
create index if not exists articles_entities_gin on public.articles using gin (entities);

-- Single source of truth for "is this High": feed view + claim_alerts both call it.
create or replace function public.high_eff(
  breaking boolean, published timestamptz, topics text[], sources integer, importance smallint
) returns boolean
language sql stable
as $$
  select published > now() - interval '6 hours'
     and ( coalesce(importance, 0) >= 3
           or ( coalesce(breaking, false)
                and case when importance is not null then importance >= 2
                         else not (topics && array['sports','entertainment','gaming','travel'])
                              or coalesce(sources, 1) >= 5
                    end ) )
$$;
revoke execute on function public.high_eff(boolean, timestamptz, text[], integer, smallint) from public;
grant execute on function public.high_eff(boolean, timestamptz, text[], integer, smallint) to anon, authenticated, service_role;

create or replace view public.feed with (security_invoker = true) as
  with base as (
    select a.id, a.url, a.title, a.excerpt, a.image_url, a.image_status,
           a.published_at, a.topics, a.regions, a.cluster_id, a.base_score, a.fts,
           s.name as source_name, s.home_url as source_home,
           coalesce(c.source_count, 1) as cluster_sources,
           public.high_eff(c.is_breaking, a.published_at, a.topics,
                           coalesce(c.source_count, 1), a.importance) as breaking_eff
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

-- claim_alerts: identical to 0025 except the fresh CTE tiers via high_eff (it used
-- raw c.is_breaking — soft-topic spam became "Breaking ·" pushes).
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
                                         coalesce(c.source_count, 1), a.importance)
                    then 25 else 0 end,
           public.high_eff(c.is_breaking, a.published_at, a.topics,
                           coalesce(c.source_count, 1), a.importance),
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

-- merge_clusters v3: keep 0017's strict embedding pass, add the entity pass.
-- >=2 shared entities + embedding guard d<0.32 + both sides recent + blob rail.
-- The guard stops "trump" gluing all politics together (1 shared entity never merges)
-- while ["xbox","microsoft"] angles of one event do — Tom's "everything Xbox" ask.
create or replace function public.merge_clusters() returns integer
language plpgsql security definer set search_path = public as $$
declare
  pair record; n integer := 0;
begin
  -- Pass 1 (0017): near-identical embeddings across cluster boundary.
  for pair in
    select distinct k.keep, k.dupe from (
      select case when ck.first_seen <= cd.first_seen then a1.cluster_id else nn.cluster_id end as keep,
             case when ck.first_seen <= cd.first_seen then nn.cluster_id else a1.cluster_id end as dupe
      from public.articles a1
      cross join lateral (
        select a2.cluster_id, a2.embedding <=> a1.embedding as d
        from public.articles a2
        where a2.embedding is not null and a2.cluster_id is not null
          and a2.cluster_id <> a1.cluster_id
          and a2.published_at > now() - interval '48 hours'
        order by a2.embedding <=> a1.embedding
        limit 1
      ) nn
      join public.clusters ck on ck.cluster_id = a1.cluster_id
      join public.clusters cd on cd.cluster_id = nn.cluster_id
      where a1.embedding is not null and a1.cluster_id is not null
        and a1.published_at > now() - interval '48 hours'
        and nn.d < 0.12
        and ck.article_count + cd.article_count <= 30   -- blob rail: stories don't hit 30 in 48h; chains do
    ) k
    limit 25
  loop
    update public.articles set cluster_id = pair.keep where cluster_id = pair.dupe;
    delete from public.clusters where cluster_id = pair.dupe;
    n := n + 1;
  end loop;

  -- Pass 2 (0029): same event, different angle. Entities land ~2h after clustering,
  -- so this only fires once enrichment has run — exactly the articles pass 1 missed.
  for pair in
    select distinct k.keep, k.dupe from (
      select case when ck.first_seen <= cd.first_seen then a1.cluster_id else a2.cluster_id end as keep,
             case when ck.first_seen <= cd.first_seen then a2.cluster_id else a1.cluster_id end as dupe
      from public.articles a1
      join public.articles a2
        on a2.cluster_id is not null
       and a2.cluster_id <> a1.cluster_id
       and a2.published_at > now() - interval '36 hours'
       and a2.entities && a1.entities
       and (select count(distinct e) from unnest(a1.entities) e where e = any(a2.entities)) >= 2
       and a1.embedding is not null and a2.embedding is not null
       and (a1.embedding <=> a2.embedding) < 0.32
      join public.clusters ck on ck.cluster_id = a1.cluster_id
      join public.clusters cd on cd.cluster_id = a2.cluster_id
      where a1.cluster_id is not null
        and a1.entities <> '{}'
        and a1.published_at > now() - interval '36 hours'
        and ck.article_count + cd.article_count <= 30
    ) k
    limit 25
  loop
    update public.articles set cluster_id = pair.keep where cluster_id = pair.dupe;
    delete from public.clusters where cluster_id = pair.dupe;
    n := n + 1;
  end loop;
  return n;
end $$;

revoke execute on function public.merge_clusters() from public, anon, authenticated;
