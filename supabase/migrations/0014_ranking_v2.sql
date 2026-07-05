-- Ranking v2 (2026-07-05 audit follow-up): the five industry-practice upgrades.
--   1. Percentile-based tiers (live pool had 2 high / 8 medium / 3037 low — dead bands)
--   2. Story clustering + multi-source velocity => breaking boost (the alerts signal)
--   3. Full-text search for custom topics (ilike matched "pineapple" for "apple")
--   4. (edge fn) keyword hint layer at ingest — coverage between source-category and Gemini
--   5. (edge fn) fixed keyword boost list retired; velocity replaces it

create extension if not exists pg_trgm;

-- ---------- 1. Percentile tiers ----------
-- Absolute thresholds rot as the source mix changes; rank the pool relatively instead.
create table if not exists public.tier_thresholds (
  only_row boolean primary key default true check (only_row),
  high_cutoff numeric not null default 70,
  medium_cutoff numeric not null default 40,
  updated_at timestamptz not null default now()
);
insert into public.tier_thresholds (only_row) values (true) on conflict do nothing;

-- high = top ~8%, medium = next ~25% of the last-24h pool; floors keep a dead news
-- day from promoting junk into High.
create or replace function public.refresh_tier_thresholds() returns void
language sql security definer set search_path = public as $$
  update public.tier_thresholds set
    high_cutoff = greatest(coalesce(p.h, 70), 30),
    medium_cutoff = greatest(coalesce(p.m, 40), 15),
    updated_at = now()
  from (
    select percentile_cont(0.92) within group (order by s) as h,
           percentile_cont(0.67) within group (order by s) as m
    from (select public.effective_score(base_score, published_at) as s
          from public.articles where published_at > now() - interval '24 hours') pool
  ) p;
$$;

create or replace function public.tier_of(score numeric) returns text
language sql stable as $$
  select case when score > t.high_cutoff then 'high'
              when score > t.medium_cutoff then 'medium'
              else 'low' end
  from public.tier_thresholds t
$$;

-- ---------- 2. Clustering + velocity ----------
create table if not exists public.clusters (
  cluster_id uuid primary key,
  first_seen timestamptz not null,
  source_count integer not null default 1,
  article_count integer not null default 1,
  is_breaking boolean not null default false,   -- >=3 distinct sources inside 45 min of first sighting
  updated_at timestamptz not null default now()
);

create index if not exists articles_title_trgm on public.articles using gin (title gin_trgm_ops);
create index if not exists articles_entities_gin on public.articles using gin (entities);

-- Attach each new article to the story it retells: shared entities (>=2) or title
-- similarity against any different-source article of the last 36h. Singletons get
-- their own cluster so later arrivals can join them. Articles stay write-once apart
-- from this one assignment; per call caps at 400 rows (cron catches up).
create or replace function public.assign_clusters() returns integer
language plpgsql security definer set search_path = public as $$
declare
  r record; m record; n integer := 0;
begin
  for r in
    select id, title, entities, source_id from public.articles
    where cluster_id is null and published_at > now() - interval '36 hours'
    order by published_at asc limit 400
  loop
    select a.cluster_id into m
    from public.articles a
    where a.id <> r.id
      and a.cluster_id is not null
      and a.published_at > now() - interval '36 hours'
      and a.source_id <> r.source_id
      and ( similarity(a.title, r.title) > 0.5
            or (r.entities <> '{}' and a.entities && r.entities
                and (select count(distinct e) from unnest(a.entities) e where e = any(r.entities)) >= 2) )
    order by similarity(a.title, r.title) desc
    limit 1;

    if m.cluster_id is not null then
      update public.articles set cluster_id = m.cluster_id where id = r.id;
      n := n + 1;
    else
      update public.articles set cluster_id = gen_random_uuid() where id = r.id;
    end if;
  end loop;

  -- Refresh cluster stats; breaking = 3+ independent sources within 45 min of first sighting.
  with g as (
    select cluster_id, min(published_at) as fs, count(distinct source_id) as sc, count(*) as ac
    from public.articles
    where cluster_id is not null and published_at > now() - interval '48 hours'
    group by 1
  ), early as (
    select a.cluster_id, count(distinct a.source_id) as esc
    from public.articles a join g on g.cluster_id = a.cluster_id
    where a.published_at <= g.fs + interval '45 minutes'
    group by 1
  )
  insert into public.clusters (cluster_id, first_seen, source_count, article_count, is_breaking, updated_at)
  select g.cluster_id, g.fs, g.sc, g.ac, coalesce(early.esc, 1) >= 3, now()
  from g left join early using (cluster_id)
  on conflict (cluster_id) do update set
    source_count = excluded.source_count,
    article_count = excluded.article_count,
    is_breaking = clusters.is_breaking or excluded.is_breaking,
    updated_at = now();

  return n;
end $$;

-- ---------- 3. Full-text search ----------
alter table public.articles add column if not exists fts tsvector
  generated always as (to_tsvector('english', title || ' ' || coalesce(excerpt, ''))) stored;
create index if not exists articles_fts on public.articles using gin (fts);

-- ---------- Feed view v2 ----------
-- Same column prefix as before (create or replace requires it); appends breaking + fts.
-- Score gains the velocity boost: a young multi-source story outranks any keyword.
create or replace view public.feed with (security_invoker = true) as
  select a.id, a.url, a.title, a.excerpt, a.image_url, a.image_status, a.published_at,
         a.topics, a.regions, a.cluster_id, s.name as source_name, s.home_url as source_home,
         (public.effective_score(a.base_score, a.published_at)
            + case when c.is_breaking and a.published_at > now() - interval '6 hours' then 25 else 0 end) as score,
         public.tier_of(public.effective_score(a.base_score, a.published_at)
            + case when c.is_breaking and a.published_at > now() - interval '6 hours' then 25 else 0 end) as tier,
         coalesce(c.is_breaking, false) as breaking,
         a.fts
  from public.articles a
  join public.sources s on s.id = a.source_id
  left join public.clusters c on c.cluster_id = a.cluster_id
  where a.published_at > now() - interval '30 days';

-- Auto-RLS enables row security on new tables; without these policies anon reads zero
-- rows, tier_of() returns NULL and the breaking boost silently disappears for clients.
create policy thresholds_read on public.tier_thresholds for select using (true);
create policy clusters_read on public.clusters for select using (true);
grant select on public.clusters, public.tier_thresholds to anon, authenticated;
grant all on public.clusters, public.tier_thresholds to service_role;

-- These run as postgres via pg_cron only — never as anon RPC through PostgREST.
revoke execute on function public.assign_clusters() from public, anon, authenticated;
revoke execute on function public.refresh_tier_thresholds() from public, anon, authenticated;

-- ---------- crons (pure SQL — no edge invocation needed) ----------
select cron.schedule('cluster_tick', '*/5 * * * *', $$select public.assign_clusters()$$);
select cron.schedule('tier_thresholds_hourly', '12 * * * *', $$select public.refresh_tier_thresholds()$$);
