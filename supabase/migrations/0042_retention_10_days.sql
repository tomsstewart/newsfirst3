-- FREE-TIER SUSTAINABILITY (APPLIED 2026-07-20): db was at 474MB of the 500MB free
-- limit. Purge kept 45 days (~260k articles / 1.2GB+ at post-gn-promotion volume —
-- guaranteed breach). 10 days ≈ 58k articles ≈ ~290MB logical, and even a 10k/day
-- spike stays under the cap. Ranking only scores the last 48h; briefs use 24h;
-- search/browse rarely need more than 10 days. The nightly 03:30 cron applies the
-- first big deletion; freed pages are reused in place so the on-disk size plateaus.
create or replace function public.purge_old_articles()
returns integer
language plpgsql security definer set search_path to 'public'
as $function$
declare n int;
begin
  delete from public.articles where published_at < now() - interval '10 days';
  get diagnostics n = row_count;
  return n;
end $function$;
