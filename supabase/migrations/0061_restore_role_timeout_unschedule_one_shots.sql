-- 0061 (2026-07-24): free-tier diet, part 4 — both one-shot VACUUM FULLs from 0060
-- succeeded (articles 09:33-09:35 UTC, 2m09s; clusters 09:37, 3s; DB 423MB -> 281MB).
-- Restore the postgres role statement_timeout and remove the one-shot jobs.

alter role postgres set statement_timeout = '2min';

select cron.unschedule('one_shot_vacuum_articles');
select cron.unschedule('one_shot_vacuum_clusters');
