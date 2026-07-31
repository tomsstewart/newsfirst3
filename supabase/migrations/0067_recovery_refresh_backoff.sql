-- 0067 (2026-07-31): recovery-ops — refresh backoff. Concurrent refresh attempts kept
-- dying at their 1200s ceiling under the post-compaction overdraft, meaning the refresh
-- cron alone could consume ~100% duty cycle in doomed work (attempt every 10 min x
-- 20 min each) — the very load preventing recovery. Attempts every 30 min while the
-- box climbs out. Restored to 1-59/10 by 0069.

select cron.alter_job(25, schedule := '1-59/30 * * * *');
