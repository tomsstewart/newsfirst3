-- 0068b (2026-07-31): recovery-ops — pause refresh entirely. Ingest has been dead since
-- ~11:50 (pg_net/edge chain starved), so articles is frozen and every 30-min refresh
-- attempt re-materializes IDENTICAL data — pure IO burn (up to 1200s each) that keeps
-- the pooler door shut with zero product benefit. Recovery order is ingest FIRST
-- (new content), then refresh. 0069 reactivates.

select cron.alter_job(25, active := false);
