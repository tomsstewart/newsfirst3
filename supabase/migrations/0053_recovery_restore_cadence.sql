-- 2026-07-22 outage, final phase: CPU credits recovered and feed_mat
-- refreshing normally again. Restore working cadences.
-- Deliberately NOT restored to pre-outage values:
--   * embed_tick: 2 min, not 15s — the 15s overlap caused the outage (0048).
--   * refresh_feed_mat: keeps the 1200s statement_timeout (0051) so a cold
--     cache can never doom-loop again; cadence back to every 10 min.
select cron.alter_job(1,  schedule := '*/5 * * * *');      -- ingest_tick
select cron.alter_job(9,  schedule := '*/5 * * * *');      -- cluster_tick
select cron.alter_job(13, schedule := '*/2 * * * *');      -- embed_tick
select cron.alter_job(14, schedule := '*/30 * * * *');     -- cluster_merge
select cron.alter_job(15, schedule := '2-59/5 * * * *');   -- alerts_tick
select cron.alter_job(20, schedule := '3-59/10 * * * *');  -- cluster_labels
select cron.alter_job(25, schedule := '1-59/10 * * * *');  -- refresh_feed_mat (keeps 1200s cmd)
