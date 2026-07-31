-- 2026-07-31: nightly maintenance (purge 03:30 / prune 03:40 / history 03:50) failed five
-- nights straight ("job startup timeout" — the box is IO-starved at that hour once bloat
-- sets in), letting articles reach 80k rows / DB 609MB, which re-bankrupted the disk-IO
-- budget (bloat -> expensive refresh+prewarm -> starvation -> maintenance fails -> more
-- bloat). Nightly monoliths are replaced by small, frequent, overlap-safe batches: a missed
-- tick self-heals on the next one and no single statement is big enough to die mid-flight.

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
    where published_at < now() - interval '4 days'
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
      and published_at < now() - interval '72 hours'
    order by published_at
    limit batch_size
    for update skip locked
  ) v
  where a.id = v.id;
  get diagnostics n = row_count;
  return n;
end $$;

-- Rewire cron: retire the nightly single points of failure, run small ticks all day.
-- Minute offsets dodge the rest of the fleet (refresh :x1, labels :x3, ingest/cluster :x0/:x5).
select cron.unschedule('purge_old_articles');
select cron.unschedule('embedding_prune');
select cron.unschedule('cron_history_purge');

select cron.schedule('purge_tick', '4-59/5 * * * *',
  $cmd$set statement_timeout = '240s'; select public.purge_articles_batch(3000)$cmd$);
select cron.schedule('embedding_prune_tick', '6-59/10 * * * *',
  $cmd$set statement_timeout = '240s'; select public.prune_embeddings_batch(3000)$cmd$);
select cron.schedule('cron_history_purge', '48 * * * *',
  $cmd$set statement_timeout = '120s'; delete from cron.job_run_details where runid in (select runid from cron.job_run_details where end_time < now() - interval '3 days' limit 10000)$cmd$);
