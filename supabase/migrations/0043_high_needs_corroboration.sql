-- High Priority showed 45 cards where ~5 belong: every angle of a big story inherits
-- Gemini importance 3, and single-source features slip through (192 importance-3
-- articles/day vs the ~40 intended). Gate: High now also needs corroboration —
-- cluster seen by >=3 sources. Uncorroborated 3s demote to medium (still prominent;
-- they return to High automatically once more sources pick the story up).
-- Matviews can't be altered in place: drop the feed stack and rebuild (seconds of
-- feed downtime; the app retries on next open/refresh). Copy this whole pattern for
-- any future feed_mat definition change — search_feed/feed/grants must come back too.

drop function if exists public.search_feed(text);
drop view if exists public.feed;
drop materialized view if exists public.feed_mat;

create materialized view public.feed_mat as
with base as (
  select a.id, a.url, a.title, a.excerpt, a.image_url, a.image_status,
         a.published_at, a.topics, a.regions, a.cluster_id, a.base_score, a.fts,
         s.name as source_name, s.home_url as source_home,
         coalesce(c.source_count, 1) as cluster_sources,
         c.label as cluster_label,
         case when article_tier(a.importance, c.is_breaking, a.published_at) = 'high'
                   and coalesce(c.source_count, 1) < 3
              then 'medium'
              else article_tier(a.importance, c.is_breaking, a.published_at)
         end as tier_v
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

create unique index feed_mat_id_idx on public.feed_mat (id);
create index feed_mat_rank_idx on public.feed_mat (score desc, published_at desc);
create index feed_mat_published_idx on public.feed_mat (published_at desc);
create index feed_mat_cluster_idx on public.feed_mat (cluster_id) where cluster_id is not null;
create index feed_mat_topics_idx on public.feed_mat using gin (topics);
create index feed_mat_source_idx on public.feed_mat (source_name, published_at desc);
create index feed_mat_fts_idx on public.feed_mat using gin (fts);

grant select on public.feed_mat to anon, authenticated;

create view public.feed as
  select id, url, title, excerpt, image_url, image_status, published_at, topics, regions,
         cluster_id, source_name, source_home, score, tier, breaking, fts,
         cluster_sources, cluster_label
  from public.feed_mat;

grant select on public.feed to anon, authenticated;

create function public.search_feed(q text)
returns setof public.feed
language sql stable
as $function$
  select f.*
  from public.feed f
  where f.fts @@ websearch_to_tsquery('english', q)
    and public.matches_keyword(f.title, f.excerpt, q)
  order by ts_rank(f.fts, websearch_to_tsquery('english', q))
           * exp(-extract(epoch from now() - f.published_at) / (36.0 * 3600))
           desc
  limit 80
$function$;

grant execute on function public.search_feed(text) to anon, authenticated;
