-- Medium tightened (Tom: "important reading for enthusiasts; most articles low").
-- Medium bar moves from the 67th to the 92nd percentile — the hourly-refreshed
-- high_cutoff, unemployed since high became breaking-only, is exactly that.
create or replace function public.tier_of(score numeric, breaking boolean, published timestamp with time zone) returns text
language sql stable as $$
  select case
    when breaking and published > now() - interval '6 hours' then 'high'
    when score > t.high_cutoff then 'medium'
    else 'low'
  end
  from public.tier_thresholds t
$$;
