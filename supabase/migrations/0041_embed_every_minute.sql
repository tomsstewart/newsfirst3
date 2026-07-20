-- Embedding coverage collapsed to ~45% after ingest volume grew to ~6.6k articles/day
-- (embed cron: 12 per 5-min tick = ~3.4k/day, sized for the old ~2.5k/day). Articles
-- without embeddings cluster by trigram title fallback, fragmenting one story across
-- many single-source clusters (the "four Andy Burnham cards" Top Stories bug).
-- Every-minute cadence = ~17k/day capacity: clears the 36h backlog in a few hours,
-- then keeps up. Per-invocation cost is unchanged (still 12 embeds/run);
-- merge_clusters retro-heals the already-fragmented clusters as embeddings land.
select cron.schedule('embed_tick', '* * * * *', $$select public.invoke_ingest('embed')$$);
