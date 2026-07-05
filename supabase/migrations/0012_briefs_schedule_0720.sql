-- Pin daily_briefs at 07:20 UTC — after the Gemini free-tier quota reset (07:00 UTC).
-- 0010 scheduled 06:45, which guarantees the day's first call can land in the
-- pre-reset window; production was already moved to 07:20 by hand — this records it.
select cron.schedule('daily_briefs', '20 7 * * *', $$select public.invoke_ingest('briefs')$$);
