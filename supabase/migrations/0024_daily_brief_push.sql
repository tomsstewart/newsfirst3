-- Daily briefing push: on by default, delivered at 10:00 LOCAL time per user.
-- The cron sweeps hourly; brief_push sends to users whose local hour (their
-- notification_settings.tz, synced by the app at device registration) equals their
-- digest_hour (default 10). Idempotent via alerts(kind='digest') within 20h.
alter table public.notification_settings
  add column if not exists daily_brief boolean not null default true;
alter table public.notification_settings alter column digest_hour set default 10;
update public.notification_settings set digest_hour = 10;   -- pre-release rows: align to the product default

select cron.schedule('brief_push_hourly', '5 * * * *', $$select public.invoke_ingest('brief_push')$$);
