-- 0059 (2026-07-24): free-tier diet, part 2 — feed stack rebuild (0043 pattern:
-- drop search_feed + feed + feed_mat, rebuild all + indexes + grants).
--
-- Changes vs 0043/0044 definition:
--   * window: published_at > now() - 4 days   (was 30 days; retention is 4 days per 0058,
--     and the narrow window also caps feed_mat if a nightly purge ever fails again)
--   * score time-bin: date_bin 1 hour          (was 15 min — it flipped on nearly every
--     10-min concurrent refresh, rewriting all ~78k rows each time; that churn was the
--     main disk-IO drain. Hourly bin => 5 of 6 refreshes diff only genuinely new/changed
--     rows. Feed ordering decay now steps hourly, which is fine for news.)
-- Everything else (columns, corroboration-gated tier logic, indexes, grants, search_feed)
-- is identical. Immediate effect in prod: feed_mat 161MB -> 49MB, DB 558MB -> 423MB.

drop function if exists public.search_feed(text);
drop view if exists public.feed;
drop materialized view if exists public.feed_mat;

create materialized view public.feed_mat as
with base as (
    select a.id,
           a.url,
           a.title,
           a.excerpt,
           a.image_url,
           a.image_status,
           a.published_at,
           a.topics,
           a.regions,
           a.cluster_id,
           a.base_score,
           a.fts,
           s.name as source_name,
           s.home_url as source_home,
           coalesce(c.source_count, 1) as cluster_sources,
           c.label as cluster_label,
           case
               when article_tier(a.importance, c.is_breaking, a.published_at) = 'high'
                    and coalesce(c.source_count, 1) < 3 then 'medium'
               else article_tier(a.importance, c.is_breaking, a.published_at)
           end as tier_v
    from articles a
    join sources s on s.id = a.source_id
    left join clusters c on c.cluster_id = a.cluster_id
    where a.published_at > now() - interval '4 days'
)
select id,
       url,
       title,
       excerpt,
       image_url,
       image_status,
       published_at,
       topics,
       regions,
       cluster_id,
       source_name,
       source_home,
       (effective_score(base_score, published_at,
                        date_bin('01:00:00'::interval, now(), '2026-01-01 00:00:00+00'::timestamptz))
        + (case tier_v when 'high' then 25 when 'medium' then 10 else 0 end)::numeric) as score,
       tier_v as tier,
       (tier_v = 'high') as breaking,
       fts,
       cluster_sources,
       cluster_label
from base;

create unique index feed_mat_id_idx on public.feed_mat using btree (id);
create index feed_mat_rank_idx on public.feed_mat using btree (score desc, published_at desc);
create index feed_mat_published_idx on public.feed_mat using btree (published_at desc);
create index feed_mat_cluster_idx on public.feed_mat using btree (cluster_id) where cluster_id is not null;
create index feed_mat_topics_idx on public.feed_mat using gin (topics);
create index feed_mat_source_idx on public.feed_mat using btree (source_name, published_at desc);
create index feed_mat_fts_idx on public.feed_mat using gin (fts);

grant select on public.feed_mat to anon, authenticated;
grant all on public.feed_mat to service_role;

create view public.feed as
select id, url, title, excerpt, image_url, image_status, published_at, topics, regions,
       cluster_id, source_name, source_home, score, tier, breaking, fts,
       cluster_sources, cluster_label
from public.feed_mat;

grant select on public.feed to anon, authenticated;
grant all on public.feed to service_role;

create or replace function public.search_feed(q text)
returns setof feed
language sql
stable
as $$
  select f.*
  from public.feed f
  where f.fts @@ websearch_to_tsquery('english', q)
    and public.matches_keyword(f.title, f.excerpt, q)
  order by ts_rank(f.fts, websearch_to_tsquery('english', q))
           * exp(-extract(epoch from now() - f.published_at) / (36.0 * 3600))
           desc
  limit 80
$$;

grant execute on function public.search_feed(text) to anon, authenticated, service_role;
