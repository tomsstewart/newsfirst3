-- Second chance for the daily briefs: Gemini free tier load-sheds (503) in the busy
-- 07:xx UTC window (killed the first-ever run, 2026-07-05). generateBriefs is
-- idempotent per day, so this no-ops (zero quota) whenever 07:20 succeeded.
select cron.schedule('daily_briefs_retry', '20 9 * * *', $$select public.invoke_ingest('briefs')$$);
