-- 0066 (2026-07-31): recovery-ops — one-shot PLAIN feed_mat refresh (0056's proven move).
-- Post-compaction starvation makes REFRESH CONCURRENTLY's diff phase (full-row *= join
-- of ~26k recomputed rows vs ~27k stale rows + two big sorts) exceed its 1200s budget;
-- a plain refresh skips the diff machinery (recompute + swap; readers block briefly).
-- One-shot at 14:47 UTC; unscheduled by 0069.

select cron.schedule('one_shot_plain_refresh', '47 14 * * *',
  $cmd$set statement_timeout = '1200s'; refresh materialized view public.feed_mat$cmd$);
