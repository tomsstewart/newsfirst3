-- 2026-07-22 outage, phase 5: full cadence (0053) proved premature — with the
-- whole fleet back, CPU credits stay pinned and cron workers fail with "job
-- startup timeout" (refresh succeeded only while the fleet was quiet).
-- Intermediate overnight cadence: feed ≤~25 min stale, alerts within 10 min,
-- ~half the burn, offsets staggered so jobs stop colliding. Restore 0053
-- values once credits have genuinely rebuilt (e.g. tomorrow).
select cron.alter_job(1,  schedule := '*/10 * * * *');     -- ingest_tick
select cron.alter_job(9,  schedule := '4-59/10 * * * *');  -- cluster_tick
select cron.alter_job(13, schedule := '*/5 * * * *');      -- embed_tick
select cron.alter_job(14, schedule := '35 * * * *');       -- cluster_merge
select cron.alter_job(15, schedule := '2-59/10 * * * *');  -- alerts_tick
select cron.alter_job(20, schedule := '13-59/20 * * * *'); -- cluster_labels
select cron.alter_job(25, schedule := '1-59/20 * * * *');  -- refresh_feed_mat
