-- 0060 (2026-07-24): free-tier diet, part 3 — one-off compaction (recovery-ops
-- migration, like 0050-0055; superseded once run, kept for the record).
--
-- After 0058's retention cut, a manual purge_old_articles() deleted 45,549 rows
-- (Tom-approved), but Postgres never returns file space without a rewrite, and
-- Supabase's "database space" metric is file size. VACUUM FULL via pg_cron one-shot
-- jobs because (a) pg_cron is the project's maintenance executor and (b) VACUUM must
-- be a single-statement command — pg_cron multi-statement commands run inside one
-- implicit transaction and VACUUM refuses. Role timeout raised so the articles
-- rewrite can't die at the 2-min default (it took 2m09s); 0061 restores it.
-- Result: DB 423MB -> 281MB (articles 341->177MB, clusters compacted).

alter role postgres set statement_timeout = '900s';

select cron.schedule('one_shot_vacuum_articles', '33 9 * * *',
  'vacuum full analyze public.articles');

select cron.schedule('one_shot_vacuum_clusters', '37 9 * * *',
  'vacuum full analyze public.clusters');
