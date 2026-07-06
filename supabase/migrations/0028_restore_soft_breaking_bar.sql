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
