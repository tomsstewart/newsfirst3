-- The feed view computed score/tier per row over the whole 30-day window on EVERY
-- request; at ~10k articles/day (post gn-source promotion, 0037) that reached ~5s —
-- past the anon role's 3s statement_timeout, so every app feed fetch 500'd and the
-- app showed no news. Materialize it and refresh from pg_cron every 5 min: reads
-- become index scans, and score decay ticks at refresh granularity (invisible in app).

create materialized view public.feed_mat as
with base as (
  select a.id, a.url, a.title, a.excerpt, a.image_url, a.image_status,
         a.published_at, a.topics, a.regions, a.cluster_id, a.base_score, a.fts,
         s.name as source_name, s.home_url as source_home,
         coalesce(c.source_count, 1) as cluster_sources,
         c.label as cluster_label,
         article_tier(a.importance, c.is_breaking, a.published_at) as tier_v
  from articles a
  join sources s on s.id = a.source_id
  left join clusters c on c.cluster_id = a.cluster_id
  where a.published_at > now() - interval '30 days'
)
select id, url, title, excerpt, image_url, image_status, published_at, topics, regions,
       cluster_id, source_name, source_home,
       effective_score(base_score, published_at)
         + (case tier_v when 'high' then 25 when 'medium' then 10 else 0 end)::numeric as score,
       tier_v as tier,
       (tier_v = 'high') as breaking,
       fts, cluster_sources, cluster_label
from base;

-- Unique index: required for REFRESH ... CONCURRENTLY (reads never block on refresh).
create unique index feed_mat_id_idx on public.feed_mat (id);
create index feed_mat_rank_idx on public.feed_mat (score desc, published_at desc);
create index feed_mat_published_idx on public.feed_mat (published_at desc);
create index feed_mat_cluster_idx on public.feed_mat (cluster_id) where cluster_id is not null;
create index feed_mat_topics_idx on public.feed_mat using gin (topics);
create index feed_mat_source_idx on public.feed_mat (source_name, published_at desc);
create index feed_mat_fts_idx on public.feed_mat using gin (fts);

grant select on public.feed_mat to anon, authenticated;

-- Same name, same columns, same rowtype: the app, search_feed(), alert_inbox and
-- existing grants are untouched; only the plan changes.
create or replace view public.feed as
  select id, url, title, excerpt, image_url, image_status, published_at, topics, regions,
         cluster_id, source_name, source_home, score, tier, breaking, fts,
         cluster_sources, cluster_label
  from public.feed_mat;

-- Offset by 1 min from the :00/:05 ingest+cluster crunch.
select cron.schedule('refresh_feed_mat', '1-59/5 * * * *',
  'refresh materialized view concurrently public.feed_mat');
