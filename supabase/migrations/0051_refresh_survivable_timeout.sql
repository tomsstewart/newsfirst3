-- The 240s timeout on refresh_feed_mat is a doom-loop design flaw: warm
-- refreshes take ~17s, but after any cold-cache/IO event a refresh needs far
-- longer, so every retry burns 240s of IO, fails, and keeps the cache cold.
-- 1200s lets a recovery refresh actually finish (runs server-side in pg_cron,
-- immune to client disconnects). Hourly at :20 during IO recovery; cadence is
-- restored by a follow-up migration once a refresh succeeds.
select cron.alter_job(
  25,
  schedule := '20 * * * *',
  command  := $cmd$set statement_timeout = '1200s'; refresh materialized view concurrently public.feed_mat$cmd$
);
