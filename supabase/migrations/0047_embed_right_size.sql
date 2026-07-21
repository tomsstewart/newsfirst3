-- n=25 hit WORKER_RESOURCE_LIMIT every run (546): the edge worker's per-request CPU
-- budget kills the isolate after ~9 gte-small embeds. Per-row patches survive the
-- kill, so 0046 still made progress — but a hard-killed isolate every 30s is not a
-- steady state, and n=12 historically hit the same cap (why coverage stalled at
-- ~57% then decayed). Right-size: 8 per request (under the observed ~9 kill point),
-- every 15 seconds = ~1.9k/h, comfortably above ~460/h arrivals.
select cron.schedule('embed_tick', '15 seconds',
  $$select public.invoke_ingest('embed&n=8')$$);
