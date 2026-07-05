-- Embeddings via Supabase's built-in gte-small (384-dim, runs inside the edge runtime):
-- gemini-embedding-001's free tier counts each batched item as a request — one
-- 100-article batch consumed the daily quota (live 429, 2026-07-05). gte-small has
-- no quota at all and never touches the Gemini key.
drop index if exists public.articles_embedding_hnsw;
alter table public.articles alter column embedding type vector(384) using (null::vector(384));
create index articles_embedding_hnsw on public.articles
  using hnsw (embedding vector_cosine_ops) where (embedding is not null);

-- gte-small inference is CPU-bound: 12 articles/invocation on a 5-min cron
-- (~3.4k/day capacity) instead of piggybacking on the ingest tick's budget.
select cron.schedule('embed_tick', '*/5 * * * *', $$select public.invoke_ingest('embed')$$);
