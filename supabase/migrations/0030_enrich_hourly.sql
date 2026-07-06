-- 0030_enrich_hourly.sql
-- Enrich hourly (was every 2h at :20): the importance rating that gates High (0029)
-- must reach an article before it ages out of the 6h breaking window. 200/run x 24 =
-- 4800/day > ~2500 new/day, so enrichment stays fully caught up. Same job name reschedules.
select cron.schedule('enrich_backfill', '20 * * * *', $$select public.invoke_ingest('enrich_backfill')$$);
