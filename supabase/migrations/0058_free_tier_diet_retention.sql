-- 0058 (2026-07-24): free-tier diet, part 1.
-- Context: Supabase emailed two free-tier warnings overnight — DB at 535MB (cap 500MB)
-- and the disk-IO budget depleting. All three nightly maintenance jobs failed at
-- 03:30–03:53 with "job startup timeout" on the IO-starved box, so the DB kept growing.
--
--   * retention 8 -> 4 days (~9k articles/day since gn promotion; 4 days ≈ 36k rows
--     keeps steady-state DB around ~300MB, well under the 500MB cap)
--   * nightly maintenance crons now set their own statement_timeout so they survive
--     a busy box instead of dying at the 2-min role default
--   * drop articles_fts (24MB GIN, 0 scans + write tax on every insert; app search and
--     claim_alerts both match fts row-wise over small sets, never via this index)

create or replace function public.purge_old_articles() returns int
language plpgsql security definer as $$
declare n int;
begin
  delete from public.articles where published_at < now() - interval '4 days';
  get diagnostics n = row_count;
  return n;
end $$;

-- cron.schedule() upserts by jobname
select cron.schedule('purge_old_articles', '30 3 * * *',
  $cmd$set statement_timeout = '600s'; select public.purge_old_articles()$cmd$);

select cron.schedule('embedding_prune', '40 3 * * *',
  $cmd$set statement_timeout = '600s'; update public.articles set embedding = null where embedding is not null and published_at < now() - interval '72 hours'$cmd$);

select cron.schedule('cron_history_purge', '50 3 * * *',
  $cmd$set statement_timeout = '300s'; delete from cron.job_run_details where end_time < now() - interval '3 days'$cmd$);

drop index if exists public.articles_fts;
