-- Daily briefing push: on by default for everyone with a registered device.
-- Timing follows the briefs pipeline (07:20 generate, 09:20 retry): push at 07:45,
-- with a 09:45 sweep for users the first run missed (briefs late, new devices).
-- brief_push is idempotent per user per day via alerts(kind='digest').
alter table public.notification_settings
  add column if not exists daily_brief boolean not null default true;

select cron.schedule('brief_push',       '45 7 * * *', $$select public.invoke_ingest('brief_push')$$);
select cron.schedule('brief_push_retry', '45 9 * * *', $$select public.invoke_ingest('brief_push')$$);
