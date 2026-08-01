-- 0070 (2026-08-01): Tom's order — get under the 500MB cap and never cross it again.
-- Three parts: (1) data diet — retention 4d -> 84h and embedding prune 72h -> 48h
-- (84h keeps a 12h buffer over ingest's 3-day skip-stale guard, so the junk-
-- resurrection loop stays dead); (2) tonight's SELF-CLEANING quiet-slot compaction
-- (03:40 UTC; a restore job at 04:15 puts the role timeout back and unschedules
-- everything including itself — no manual follow-up); (3) db_size_mb() so the
-- watchdog (v48) can page BEFORE the cap instead of Supabase emailing after.

create or replace function public.purge_old_articles()
returns integer
language plpgsql
security definer
as $$
declare n int;
begin
  delete from public.articles where published_at < now() - interval '84 hours';
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.purge_articles_batch(batch_size int default 3000)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare n int;
begin
  delete from public.articles a
  using (
    select id from public.articles
    where published_at < now() - interval '84 hours'
    order by published_at
    limit batch_size
    for update skip locked
  ) v
  where a.id = v.id;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.prune_embeddings_batch(batch_size int default 3000)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare n int;
begin
  update public.articles a
  set embedding = null
  from (
    select id from public.articles
    where embedding is not null
      and published_at < now() - interval '48 hours'
    order by published_at
    limit batch_size
    for update skip locked
  ) v
  where a.id = v.id;
  get diagnostics n = row_count;
  return n;
end $$;

-- Size guard for the watchdog (edge v48 calls rpc/db_size_mb, pages > 460MB).
create or replace function public.db_size_mb()
returns integer
language sql
security definer
stable
as $$ select (pg_database_size(current_database()) / 1024 / 1024)::int $$;
revoke execute on function public.db_size_mb() from public, anon, authenticated;
grant execute on function public.db_size_mb() to service_role;

-- Tonight's compaction, fully self-cleaning. Role timeout raised for the rewrites;
-- the 04:15 restore job puts it back and removes all four one-shots (itself included).
alter role postgres set statement_timeout = '1200s';

select cron.schedule('one_shot_vac_articles_0801', '40 3 * * *',
  'vacuum full analyze public.articles');
select cron.schedule('one_shot_vac_feedmat_0801', '46 3 * * *',
  'vacuum full analyze public.feed_mat');
select cron.schedule('one_shot_vac_misc_0801', '50 3 * * *',
  'vacuum full analyze public.clusters');
select cron.schedule('one_shot_restore_0801', '15 4 * * *',
  $cmd$alter role postgres set statement_timeout = '2min'; select cron.unschedule('one_shot_vac_articles_0801'); select cron.unschedule('one_shot_vac_feedmat_0801'); select cron.unschedule('one_shot_vac_misc_0801'); select cron.unschedule('one_shot_restore_0801')$cmd$);
