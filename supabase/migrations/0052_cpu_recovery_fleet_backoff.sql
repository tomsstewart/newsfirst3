-- 2026-07-22 outage, phase 3: the box is out of burstable CPU credits (SSL
-- handshake failures, cron startup timeouts, 12s catalog scans). The failing
-- jobs themselves burn the recovering credits (cluster jobs grind to their
-- 60-90s timeouts all day). Back the whole fleet off so credits accrue;
-- restored by follow-up migration after feed_mat refreshes successfully.
select cron.alter_job(1,  schedule := '*/15 * * * *');  -- ingest_tick, was */5 (keep news flowing, lighter)
select cron.alter_job(9,  schedule := '25 * * * *');    -- cluster_tick, was */5
select cron.alter_job(14, schedule := '35 * * * *');    -- cluster_merge, was */30
select cron.alter_job(15, schedule := '*/15 * * * *');  -- alerts_tick, was 2-59/5
select cron.alter_job(20, schedule := '55 * * * *');    -- cluster_labels, was 3-59/10
-- embed_tick(13) already hourly :45, enrich_backfill(4) hourly :20,
-- refresh_feed_mat(25) hourly :20 @ 1200s — unchanged.
