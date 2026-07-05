-- Sport was flooding High tier: match coverage trivially hits 3-sources-in-45-min
-- (every outlet files at the final whistle). Soft topics (sports/entertainment/
-- gaming/travel) now need 5+ corroborating sources to count as breaking — a real
-- upset still qualifies, a routine result doesn't. Applies to the tier, the +25
-- boost AND the exposed breaking flag (so the bell inbox calms down too).
create or replace view public.feed with (security_invoker = true) as
  with base as (
    select a.*, s.name as source_name, s.home_url as source_home,
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
         (public.effective_score(base_score, published_at) + case when breaking_eff then 25 else 0 end) as score,
         public.tier_of(
            public.effective_score(base_score, published_at) + case when breaking_eff then 25 else 0 end,
            breaking_eff,
            published_at) as tier,
         breaking_eff as breaking,
         fts,
         cluster_sources
  from base;
