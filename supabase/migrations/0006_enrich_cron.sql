-- Enrichment batch: one Gemini call per run, every 2h = 12 calls/day (free tier: 20/day).
select cron.schedule('enrich_backfill', '20 */2 * * *', $$select public.invoke_ingest('enrich_backfill')$$);
