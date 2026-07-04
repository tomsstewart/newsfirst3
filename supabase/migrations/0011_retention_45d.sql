-- 121 sources ≈ 2.5k articles/day; 90-day retention would breach the 500MB free tier
-- in ~2-3 months. Feed shows 30 days; 45 keeps headroom for search/backfill.
create or replace function public.purge_old_articles()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  delete from public.articles where published_at < now() - interval '45 days';
  get diagnostics n = row_count;
  return n;
end $$;
