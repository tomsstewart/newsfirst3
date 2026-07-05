-- HIGH tier redefined (Tom's call): high = notification-worthy = a breaking story —
-- 3+ independent sources inside 45 minutes, still fresh (<6h). Score percentiles only
-- separate medium from low now. This makes the High band literally the future push
-- trigger, not "today's better articles".
create or replace function public.tier_of(score numeric, breaking boolean, published timestamp with time zone) returns text
language sql stable as $$
  select case
    when breaking and published > now() - interval '6 hours' then 'high'
    when score > t.medium_cutoff then 'medium'
    else 'low'
  end
  from public.tier_thresholds t
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
            a.published_at) as tier,
         coalesce(c.is_breaking, false) as breaking,
         a.fts,
         coalesce(c.source_count, 1) as cluster_sources
  from public.articles a
  join public.sources s on s.id = a.source_id
  left join public.clusters c on c.cluster_id = a.cluster_id
  where a.published_at > now() - interval '30 days';
