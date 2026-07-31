-- 0069 (2026-07-31): THE RESTORE — undoes every temporary recovery measure from the
-- 07-31 incident once the box is stable (apply when: a refresh has SUCCEEDED, ingest
-- is inserting again, and connections are reliable). MUST run before 12:02 UTC
-- 2026-08-01 (one-shot vacuums are daily entries) — earlier is better.
-- Restores the 0057 day cadence exactly, plus the 0062 maintenance ticks.

-- 1) reactivate the deep-shed pauses (0068)
select cron.alter_job(13, active := true);
select cron.alter_job(9,  active := true);
select cron.alter_job(20, active := true);
select cron.alter_job(14, active := true);
select cron.alter_job(10, active := true);
select cron.alter_job(16, active := true);
select cron.alter_job(4,  active := true);
select cron.alter_job(38, active := true);
select cron.alter_job(39, active := true);

-- 2) restore cadences (0065/0067)
select cron.alter_job(13, schedule := '15 seconds');       -- embed (safe: claim_embed_batch)
select cron.alter_job(9,  schedule := '*/5 * * * *');      -- cluster_tick
select cron.alter_job(25, schedule := '1-59/10 * * * *');  -- refresh

-- 3) role timeout back to sane default (0064 raised it; also caps runaway ad-hoc queries)
alter role postgres set statement_timeout = '2min';

-- 4) remove the one-shots (0064/0066) BEFORE they fire again tomorrow
select cron.unschedule('one_shot_vacuum_articles');
select cron.unschedule('one_shot_vacuum_feed_mat');
select cron.unschedule('one_shot_plain_refresh');
