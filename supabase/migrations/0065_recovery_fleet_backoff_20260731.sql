-- 0065 (2026-07-31): recovery-ops (0052 pattern) — TEMPORARY fleet backoff while the
-- box works off the IO debt of the 12:02 VACUUM FULL compaction. The rewrite finished
-- (articles 447MB -> ~110MB) but drained the remaining disk-IO budget; at floor
-- throughput every 10-min refresh attempt burns its 1200s budget and fails, keeping
-- the box pinned (the 2026-07-22 lesson: fix load-shape, not timeouts).
--   embed_tick   15s  -> every 2 min
--   cluster_tick */5  -> */15  (was failing its 90s timeout every run = pure burn)
-- Restored by 0069.

select cron.alter_job(13, schedule := '*/2 * * * *');
select cron.alter_job(9, schedule := '*/15 * * * *');
