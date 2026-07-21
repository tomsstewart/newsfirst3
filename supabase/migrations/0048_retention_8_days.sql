-- DB plateaued at ~503MB — over the 500MB free-tier cap (embedding backfill from the
-- 07-21 fix added ~25MB, and feed_mat's concurrent-refresh churn re-bloats between
-- nightly vacuums). 10-day retention left no headroom; 8 days shrinks the working
-- set ~20% (articles heap/indexes AND feed_mat, whose rows come from articles).
create or replace function public.purge_old_articles() returns integer
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  delete from public.articles where published_at < now() - interval '8 days';
  get diagnostics n = row_count;
  return n;
end $$;
