set local lock_timeout = '8s';

-- Embed workers previously SELECTed the same "newest unembedded" rows and all
-- PATCHed them, serializing on tuple locks whenever ticks overlapped (the
-- 2026-07-22 feed_mat outage). claim_embed_batch hands each caller a disjoint
-- batch: SKIP LOCKED avoids contention inside the statement, embed_claimed_at
-- keeps later callers off a batch already handed out. Claims older than 10 min
-- (worker died mid-batch) are reclaimable.
-- NB: no dedicated queue index — the 36h published_at range via
-- articles_published_idx bounds the scan to ~2.5k rows, plenty. (A partial
-- index build could not complete on the IO-starved box; see 0052.)

alter table public.articles add column if not exists embed_claimed_at timestamptz;

create or replace function public.claim_embed_batch(n int default 8)
returns table (id uuid, title text, excerpt text)
language sql
as $$
  update articles a
     set embed_claimed_at = now()
    from (
      select id
        from articles
       where embedding is null
         and published_at > now() - interval '36 hours'
         and (embed_claimed_at is null or embed_claimed_at < now() - interval '10 minutes')
       order by published_at desc
       limit n
       for update skip locked
    ) picked
   where a.id = picked.id
   returning a.id, a.title, a.excerpt;
$$;
