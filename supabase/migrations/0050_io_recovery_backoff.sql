-- 2026-07-22 outage, phase 2: the morning's embed lock storm exhausted the
-- instance's disk-IO burst budget. Even trivial scans now time out, and the
-- feed_mat refresh doom-loops (240s of IO every 10 min, then dies), keeping
-- the budget pinned at zero. Back both jobs off to hourly so IO can recover;
-- a follow-up migration restores normal cadence after a successful manual
-- refresh. (Not disabled: hourly means they self-resume regardless.)
select cron.alter_job(13, schedule := '45 * * * *');  -- embed_tick, was */2
select cron.alter_job(25, schedule := '50 * * * *');  -- refresh_feed_mat, was 1-59/10
