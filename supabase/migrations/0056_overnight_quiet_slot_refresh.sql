-- 2026-07-22 outage, phase 7: prewarm alone didn't save the refresh (20:20 run
-- burned 25 min) — on this credit-starved box the big refresh only completes
-- when the fleet is quiet (18:20 proof: 40s). So carve an explicit quiet slot:
-- ALL periodic jobs run only :34-:58; refresh owns :59-:34 alone, firing at
-- :05. Overnight it also uses a PLAIN refresh (no CONCURRENTLY): skips the
-- whole diff phase, ~2-4x cheaper; readers block only for its runtime, which
-- in a quiet slot is ~a minute, and the app has ~no readers overnight.
-- Feed staleness <=~70 min, under the watchdog's 90-min page threshold.
-- Restore 0053 cadences + CONCURRENTLY once credits rebuild (tomorrow).
select cron.alter_job(1,  schedule := '35-55/10 * * * *'); -- ingest_tick    :35 :45 :55
select cron.alter_job(2,  schedule := '37 * * * *');       -- health_watchdog (was :07, inside quiet slot)
select cron.alter_job(4,  schedule := '40 * * * *');       -- enrich_backfill (was :20 — collided with refresh)
select cron.alter_job(9,  schedule := '38-58/10 * * * *'); -- cluster_tick   :38 :48 :58
select cron.alter_job(13, schedule := '34-58/8 * * * *');  -- embed_tick     :34 :42 :50 :58
select cron.alter_job(14, schedule := '54 * * * *');       -- cluster_merge
select cron.alter_job(15, schedule := '36-56/10 * * * *'); -- alerts_tick    :36 :46 :56
select cron.alter_job(20, schedule := '52 * * * *');       -- cluster_labels
select cron.alter_job(
  25,
  schedule := '5 * * * *',
  command  := $cmd$set statement_timeout = '1500s'; select extensions.pg_prewarm('public.articles'::regclass, 'read'); refresh materialized view public.feed_mat$cmd$
);
