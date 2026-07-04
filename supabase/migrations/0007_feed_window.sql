-- 48h starved low-frequency sources/topics (weekly blogs never surfaced).
-- 7 days + read-time decay keeps ordering sane while giving every source a shelf.
create or replace view public.feed
with (security_invoker = true) as
select
  a.id, a.url, a.title, a.excerpt, a.image_url, a.image_status,
  a.published_at, a.topics, a.regions, a.cluster_id,
  s.name  as source_name,
  s.home_url as source_home,
  public.effective_score(a.base_score, a.published_at) as score,
  public.priority_tier(a.base_score, a.published_at)  as tier
from public.articles a
join public.sources s on s.id = a.source_id
where a.published_at > now() - interval '7 days';
