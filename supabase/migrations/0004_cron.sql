-- Scheduling for the ingest edge function + retention.
-- v2's sin: the service key sat in PLAINTEXT inside anon-readable cron commands.
-- v3: the key lives in Vault; a locked-down SECURITY DEFINER helper reads it at call time.
--
-- ONE-TIME MANUAL STEP (owner, SQL editor) — store the service role key in Vault:
--   select vault.create_secret('<service-role-key from Dashboard → Settings → API>', 'service_role_key');

create extension if not exists pg_cron;
create extension if not exists pg_net;

create or replace function public.invoke_ingest(task text)
returns void
language plpgsql security definer set search_path = public
as $$
declare key text;
begin
  select decrypted_secret into key from vault.decrypted_secrets where name = 'service_role_key';
  if key is null then
    raise warning 'vault secret service_role_key missing - ingest not invoked';
    return;
  end if;
  perform net.http_post(
    url := 'https://sbqdvtzsezxupxxbmjsb.supabase.co/functions/v1/ingest?task=' || task,
    headers := jsonb_build_object('Authorization', 'Bearer ' || key, 'Content-Type', 'application/json'),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000
  );
end $$;

-- Nobody but the cron runner (postgres) may execute this.
revoke all on function public.invoke_ingest(text) from public, anon, authenticated;

select cron.schedule('ingest_tick',        '*/5 * * * *', $$select public.invoke_ingest('ingest')$$);
select cron.schedule('health_watchdog',    '7 * * * *',   $$select public.invoke_ingest('watchdog')$$);
select cron.schedule('purge_old_articles', '30 3 * * *',  $$select public.purge_old_articles()$$);
