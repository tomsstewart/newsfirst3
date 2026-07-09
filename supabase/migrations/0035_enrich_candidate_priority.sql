-- 0035_enrich_candidate_priority.sql
-- Fix the Gemini reliance (Tom, 2026-07-10): the free tier is ~20 calls/day, and the
-- backfill was rating the newest 200 unrated articles regardless of whether they could
-- ever be High/Medium — so quota got spent on routine filler and the actual tier
-- CANDIDATES (recent, corroborated hard news) often stayed unrated → High/Medium empty.
-- Tiers only look at the last 6h, and High/Medium need importance, so rate the
-- tier-relevant window first, breaking + most-corroborated first. Recent unrated is a
-- small set (~hundreds/day), so 2-3 calls cover it and Gemini never "runs out" for the
-- stuff that matters. Older/routine articles simply stay Low (correct).
create or replace function public.unrated_for_enrich(lim integer default 200)
returns table(id uuid, title text, excerpt text, topics text[], regions text[])
language sql stable security definer set search_path = public
as $$
  select a.id, a.title, a.excerpt, a.topics, a.regions
  from public.articles a
  left join public.clusters c on c.cluster_id = a.cluster_id
  where a.importance is null
    and a.published_at > now() - interval '12 hours'
  order by coalesce(c.is_breaking, false) desc,   -- corroborated candidates first
           coalesce(c.source_count, 1) desc,
           a.published_at desc
  limit lim;
$$;
revoke execute on function public.unrated_for_enrich(integer) from public, anon, authenticated;
grant execute on function public.unrated_for_enrich(integer) to service_role;
