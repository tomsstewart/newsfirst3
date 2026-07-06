-- Per-topic medium band (Tom: "why is tech missing any prioritization bars"):
-- medium was a GLOBAL top-8% score percentile, which weight-5 heavyweights
-- (Bloomberg/FT/BBC) monopolised — tech had 580 low / 0 medium. Every topic now
-- gets its own 92nd-percentile cutoff over its own 24h pool, so each pane has a
-- meaningful Medium band. High stays breaking-only (unchanged). Topics with thin
-- pools (<30 articles/24h) fall back to the global cutoff.

create table if not exists public.tier_thresholds_topic (
  topic         text primary key,
  medium_cutoff numeric not null,
  sample        integer not null,
  updated_at    timestamptz not null default now()
);
-- Auto-RLS project: without an explicit policy anon reads 0 rows and the feed
-- view's tier silently degrades (the 0014 gotcha).
alter table public.tier_thresholds_topic enable row level security;
drop policy if exists tiers_topic_read on public.tier_thresholds_topic;
create policy tiers_topic_read on public.tier_thresholds_topic for select using (true);
grant select on public.tier_thresholds_topic to anon, authenticated;
grant all on public.tier_thresholds_topic to service_role;

create or replace function public.refresh_tier_thresholds()
returns void
language sql security definer set search_path = public
as $$
  update public.tier_thresholds set
    high_cutoff = greatest(coalesce(p.h, 70), 30),
    medium_cutoff = greatest(coalesce(p.m, 40), 15),
    updated_at = now()
  from (
    select percentile_cont(0.92) within group (order by s) as h,
           percentile_cont(0.67) within group (order by s) as m
    from (
      select public.effective_score(a.base_score, a.published_at)
             + case when c.is_breaking and a.published_at > now() - interval '6 hours' then 25 else 0 end as s
      from public.articles a
      left join public.clusters c on c.cluster_id = a.cluster_id
      where a.published_at > now() - interval '24 hours'
    ) pool
  ) p;

  insert into public.tier_thresholds_topic (topic, medium_cutoff, sample, updated_at)
  select t.topic,
         greatest(percentile_cont(0.92) within group (order by t.s), 15),
         count(*)::int,
         now()
  from (
    select unnest(a.topics) as topic,
           public.effective_score(a.base_score, a.published_at)
             + case when c.is_breaking and a.published_at > now() - interval '6 hours' then 25 else 0 end as s
    from public.articles a
    left join public.clusters c on c.cluster_id = a.cluster_id
    where a.published_at > now() - interval '24 hours'
  ) t
  group by t.topic
  having count(*) >= 30
  on conflict (topic) do update set
    medium_cutoff = excluded.medium_cutoff,
    sample = excluded.sample,
    updated_at = now();

  -- Topics that fell below the sample floor revert to the global fallback.
  delete from public.tier_thresholds_topic tt
  where tt.updated_at < now() - interval '3 hours';
$$;

-- Topic-aware tier: medium = top 8% within ANY of the article's own topics
-- (min applicable cutoff); topics without a row fall back to the global bar.
create or replace function public.tier_of(score numeric, breaking boolean, published timestamptz, topics text[])
returns text
language sql stable
as $$
  select case
    when breaking and published > now() - interval '6 hours' then 'high'
    when score > coalesce(
           (select min(tt.medium_cutoff) from public.tier_thresholds_topic tt where tt.topic = any(topics)),
           (select t.high_cutoff from public.tier_thresholds t))
      then 'medium'
    else 'low'
  end
$$;

create or replace view public.feed with (security_invoker = true) as
  select a.id, a.url, a.title, a.excerpt, a.image_url, a.image_status, a.published_at,
         a.topics, a.regions, a.cluster_id, s.name as source_name, s.home_url as source_home,
         (public.effective_score(a.base_score, a.published_at)
            + case when c.is_breaking and a.published_at > now() - interval '6 hours' then 25 else 0 end) as score,
         public.tier_of(
            public.effective_score(a.base_score, a.published_at)
              + case when c.is_breaking and a.published_at > now() - interval '6 hours' then 25 else 0 end,
            coalesce(c.is_breaking, false),
            a.published_at,
            a.topics) as tier,
         coalesce(c.is_breaking, false) as breaking,
         a.fts,
         coalesce(c.source_count, 1) as cluster_sources
  from public.articles a
  join public.sources s on s.id = a.source_id
  left join public.clusters c on c.cluster_id = a.cluster_id
  where a.published_at > now() - interval '30 days';

-- Matcher uses the same topic-aware tier (notify_level 'high' semantics unchanged:
-- high still means breaking, which tier_of computes identically).
select public.refresh_tier_thresholds();
