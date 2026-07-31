-- 0068 (2026-07-31): recovery-ops — deep shed. Four hours post-compaction the box was
-- still in IO overdraft: pooler refusing connections during refresh attempts, edge
-- function 500ing on DB timeouts, ingest dead since ~11:50 UTC. Moderate backoff
-- (0065/0067) wasn't enough: replenishment ~= consumption. Pause EVERYTHING that does
-- not matter tonight so the trickle goes to ingest (content), refresh (visibility) and
-- alerts. Deactivated, not unscheduled — 0069 flips active back on.
--   paused: embed_tick(13), cluster_tick(9), cluster_labels(20), cluster_merge(14),
--           tier_thresholds_hourly(10), brief_push_hourly(16), enrich_backfill(4),
--           purge_tick(38), embedding_prune_tick(39)   [purge/prune backlogs EMPTY]
--   kept:   ingest_tick(1), alerts_tick(15), refresh_feed_mat(25 @ :01/:31),
--           health_watchdog(2), cron_history_purge(40), daily briefs (time-gated)

select cron.alter_job(13, active := false);
select cron.alter_job(9,  active := false);
select cron.alter_job(20, active := false);
select cron.alter_job(14, active := false);
select cron.alter_job(10, active := false);
select cron.alter_job(16, active := false);
select cron.alter_job(4,  active := false);
select cron.alter_job(38, active := false);
select cron.alter_job(39, active := false);
