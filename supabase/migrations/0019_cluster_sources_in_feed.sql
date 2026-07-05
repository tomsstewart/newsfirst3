-- Full Coverage (Google News-style): clients need each article's cluster breadth to
-- decide when to show the "Full coverage · N sources" affordance.
create or replace view public.feed with (security_invoker = true) as
  select a.id, a.url, a.title, a.excerpt, a.image_url, a.image_status, a.published_at,
         a.topics, a.regions, a.cluster_id, s.name as source_name, s.home_url as source_home,
         (public.effective_score(a.base_score, a.published_at)
            + case when c.is_breaking and a.published_at > now() - interval '6 hours' then 25 else 0 end) as score,
         public.tier_of(public.effective_score(a.base_score, a.published_at)
            + case when c.is_breaking and a.published_at > now() - interval '6 hours' then 25 else 0 end) as tier,
         coalesce(c.is_breaking, false) as breaking,
         a.fts,
         coalesce(c.source_count, 1) as cluster_sources
  from public.articles a
  join public.sources s on s.id = a.source_id
  left join public.clusters c on c.cluster_id = a.cluster_id
  where a.published_at > now() - interval '30 days';
