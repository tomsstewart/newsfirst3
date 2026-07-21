-- Embedding capacity was sized for ~2.5k articles/day (12 per tick, every 5 min =
-- ~3.4k/day). Post gn-promotion volume is ~11k/day, so coverage decayed to ~23%,
-- clustering fragmented, cluster_sources collapsed to 1, and 0043's corroboration
-- gate demoted every would-be High card: Top Stories went empty.
--
-- gte-small runs inside the edge runtime (no external API/quota), so the only cost
-- of more throughput is edge CPU. 25 every 30s = ~72k/day ceiling; the function
-- stores each embedding as it goes, so a worker CPU kill mid-batch keeps progress.
-- (invoke_ingest concatenates its arg into the URL query string, so 'embed&n=25'
-- reaches the edge function as task=embed, n=25.)
select cron.schedule('embed_tick', '30 seconds',
  $$select public.invoke_ingest('embed&n=25')$$);

-- pg_cron history hygiene: at sub-minute cadence job_run_details grows fast.
select cron.schedule('cron_history_purge', '50 3 * * *',
  $$delete from cron.job_run_details where end_time < now() - interval '3 days'$$);
