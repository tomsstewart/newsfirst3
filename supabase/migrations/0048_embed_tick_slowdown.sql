-- Emergency mitigation, 2026-07-22 feed outage: embed_tick ran every 15s but
-- each invoke_ingest('embed&n=8') takes 10-16s, so runs permanently overlapped
-- and workers serialized on articles tuple locks, starving feed_mat refresh
-- (failed continuously 07:21-12:20 UTC). 2-min cadence keeps runs disjoint.
-- (Prefix collides with 0048_retention_8_days — applied same-day from a
-- different session; remote versions are timestamps so both are recorded.)
select cron.alter_job(13, schedule := '*/2 * * * *');
