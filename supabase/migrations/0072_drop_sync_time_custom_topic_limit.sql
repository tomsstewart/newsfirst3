-- Custom-topic limits are enforced client-side at add-time (Entitlements:
-- 3 free, unlimited premium/comped, paywall sheet on the 4th). The sync-time
-- trigger (in place since 0001_init) rejected the WHOLE batched upsert when a
-- free-plan user exceeded the cap, wedging topic sync entirely: every POST
-- 400'd ("free plan allows up to 3 custom topics"), no bell levels ever
-- landed, and the client silently showed local state as saved (2026-08-02).
-- It also fired per-row on upserts of EXISTING topics, so a free user at
-- exactly 3 customs could never sync again at all.
--
-- The client mirrors entitlement into profiles.plan (AuthClient.syncPlan,
-- upgrade-only) so server-side plan logic stays possible; blocking mid-sync
-- is not how it should be enforced.
--
-- Applied to prod via MCP 2026-08-02 22:10 UTC.
drop trigger if exists custom_topic_limit on public.topic_subscriptions;
drop function if exists public.enforce_custom_topic_limit();
