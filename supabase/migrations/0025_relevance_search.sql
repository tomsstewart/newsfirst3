-- Custom-topic search ranked by RELEVANCE × freshness instead of pure recency
-- (recency-only ordering front-loaded whichever blog posted last, and buried
-- strong matches from hours earlier). 36h half-life keeps it a news search.
create or replace function public.search_feed(q text)
returns setof public.feed
language sql stable as $$
  select f.*
  from public.feed f
  where f.fts @@ websearch_to_tsquery('english', q)
  order by ts_rank(f.fts, websearch_to_tsquery('english', q))
           * exp(-extract(epoch from now() - f.published_at) / (36.0 * 3600))
           desc
  limit 80
$$;
grant execute on function public.search_feed(text) to anon, authenticated;
