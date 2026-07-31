-- 0064 (2026-07-31): incident recovery, part 3 — one-off compaction (recovery-ops
-- migration like 0060; superseded once run, kept for the record).
--
-- Five nights of failed maintenance let articles bloat to 80k rows / 447MB (DB 609MB,
-- over the 500MB free cap). The batched ticks (0062) have now purged ~53k rows and
-- pruned stale embeddings, but Postgres never returns file space without a rewrite,
-- and Supabase's "database space" metric is file size — worse, pg_prewarm re-reads the
-- physical heap every 10 min, so dead space directly drains the disk-IO budget.
-- VACUUM FULL via pg_cron one-shots (single-statement commands; VACUUM refuses to run
-- inside pg_cron's multi-statement implicit transaction). Role timeout raised so the
-- articles rewrite can't die at the 2-min default; 0065 restores it and unschedules.
-- Timing: 12:02 sits right after the 12:01 refresh; feed_mat at 12:08 between refreshes.

alter role postgres set statement_timeout = '1200s';

select cron.schedule('one_shot_vacuum_articles', '2 12 * * *',
  'vacuum full analyze public.articles');

select cron.schedule('one_shot_vacuum_feed_mat', '8 12 * * *',
  'vacuum full analyze public.feed_mat');
