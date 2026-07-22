-- 2026-07-22 outage, phase 6: even at intermediate cadence a cold-cache
-- CONCURRENTLY refresh needs >20 min on the credit-starved box (19:21 run
-- burned its full 1200s), while the warm-cache 18:20 run took 40s. So make
-- each refresh warm its own cache: pg_prewarm in 'read' mode pulls both heaps
-- through the OS page cache with sequential IO (the cheapest kind on a
-- throttled volume) before the refresh touches them. Hourly overnight at the
-- proven :20 slot; embed eased to 10-min. Restore 0053 cadences tomorrow.
create extension if not exists pg_prewarm with schema extensions;

select cron.alter_job(
  25,
  schedule := '20 * * * *',
  command  := $cmd$set statement_timeout = '1500s'; select extensions.pg_prewarm('public.articles'::regclass, 'read'); select extensions.pg_prewarm('public.feed_mat'::regclass, 'read'); refresh materialized view concurrently public.feed_mat$cmd$
);

select cron.alter_job(13, schedule := '*/10 * * * *');  -- embed_tick: backlog drain resumes tomorrow
