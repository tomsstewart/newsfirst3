-- The tier is assigned to (effective_score + breaking boost) in the feed view, but the
-- percentile pool ranked plain effective_score — boosted articles floated above a
-- cutoff computed without them. Rank the same quantity that gets tiered.
create or replace function public.refresh_tier_thresholds() returns void
language sql security definer set search_path = public as $$
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
$$;
revoke execute on function public.refresh_tier_thresholds() from public, anon, authenticated;
