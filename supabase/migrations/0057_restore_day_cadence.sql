-- 2026-07-23 morning: CPU credits rebuilt (8 consecutive overnight refreshes
-- at 17-21s), ratings flowing again post-quota-reset. Restore day cadence.
-- embed_tick returns to 15s: the outage cause was the racing GET (fixed by
-- claim_embed_batch/SKIP LOCKED in 0049 + ingest v45), not the cadence itself,
-- and the 6.7k embed backlog needs ~1.9k/hr to drain before clusters can
-- corroborate the high tier. Refresh keeps prewarm + 1200s (0051/0055) but
-- returns to CONCURRENTLY (readers matter in the day) every 10 min.
select cron.alter_job(1,  schedule := '*/5 * * * *');      -- ingest_tick
select cron.alter_job(2,  schedule := '7 * * * *');        -- health_watchdog
select cron.alter_job(4,  schedule := '20 * * * *');       -- enrich_backfill
select cron.alter_job(9,  schedule := '*/5 * * * *');      -- cluster_tick
select cron.alter_job(13, schedule := '15 seconds');       -- embed_tick
select cron.alter_job(14, schedule := '*/30 * * * *');     -- cluster_merge
select cron.alter_job(15, schedule := '2-59/5 * * * *');   -- alerts_tick
select cron.alter_job(20, schedule := '3-59/10 * * * *');  -- cluster_labels
select cron.alter_job(
  25,
  schedule := '1-59/10 * * * *',
  command  := $cmd$set statement_timeout = '1200s'; select extensions.pg_prewarm('public.articles'::regclass, 'read'); refresh materialized view concurrently public.feed_mat$cmd$
);
