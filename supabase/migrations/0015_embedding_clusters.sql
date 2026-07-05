-- Clustering v2: semantic embeddings heal fragmentation (trigram matching split one
-- story into several clusters when retellings shared no title wording — e.g. the
-- 2026-07-05 Swift wedding landed in 3 clusters).
--
-- Cost model: gemini-embedding-001 has its OWN free-tier quota (separate from the
-- 20/day generation cap); embeddings are only needed inside the 36-48h clustering
-- window, so they're pruned after 72h — steady-state storage is a few MB.

create extension if not exists vector;

alter table public.articles add column if not exists embedding vector(256);

-- HNSW so nearest-neighbour lookups stay index-driven as the window grows.
create index if not exists articles_embedding_hnsw on public.articles
  using hnsw (embedding vector_cosine_ops) where (embedding is not null);

-- ---------- assignment v2: embedding-first, trigram/entity fallback ----------
create or replace function public.assign_clusters() returns integer
language plpgsql security definer set search_path = public as $$
declare
  r record; target uuid; n integer := 0;
begin
  for r in
    select id, title, entities, source_id, embedding from public.articles
    where cluster_id is null and published_at > now() - interval '36 hours'
    order by published_at asc limit 400
  loop
    target := null;

    -- Semantic match first: same story retold with entirely different words still lands.
    if r.embedding is not null then
      select a.cluster_id into target
      from public.articles a
      where a.embedding is not null and a.cluster_id is not null
        and a.id <> r.id
        and a.published_at > now() - interval '36 hours'
        and a.source_id <> r.source_id
        and (a.embedding <=> r.embedding) < 0.30
      order by a.embedding <=> r.embedding
      limit 1;
    end if;

    -- Fallback for not-yet-embedded articles (embeddings lag ingest by <=1 tick;
    -- merge_clusters retro-corrects anything mis-assigned in that gap).
    if target is null then
      select a.cluster_id into target
      from public.articles a
      where a.id <> r.id
        and a.cluster_id is not null
        and a.published_at > now() - interval '36 hours'
        and a.source_id <> r.source_id
        and ( similarity(a.title, r.title) > 0.5
              or (r.entities <> '{}' and a.entities && r.entities
                  and (select count(distinct e) from unnest(a.entities) e where e = any(r.entities)) >= 2) )
      order by similarity(a.title, r.title) desc
      limit 1;
    end if;

    if target is not null then
      update public.articles set cluster_id = target where id = r.id;
      n := n + 1;
    else
      update public.articles set cluster_id = gen_random_uuid() where id = r.id;
    end if;
  end loop;

  -- Refresh cluster stats; breaking = 3+ independent sources within 45 min of first sighting.
  with g as (
    select cluster_id, min(published_at) as fs, count(distinct source_id) as sc, count(*) as ac
    from public.articles
    where cluster_id is not null and published_at > now() - interval '48 hours'
    group by 1
  ), early as (
    select a.cluster_id, count(distinct a.source_id) as esc
    from public.articles a join g on g.cluster_id = a.cluster_id
    where a.published_at <= g.fs + interval '45 minutes'
    group by 1
  )
  insert into public.clusters (cluster_id, first_seen, source_count, article_count, is_breaking, updated_at)
  select g.cluster_id, g.fs, g.sc, g.ac, coalesce(early.esc, 1) >= 3, now()
  from g left join early using (cluster_id)
  on conflict (cluster_id) do update set
    source_count = excluded.source_count,
    article_count = excluded.article_count,
    is_breaking = clusters.is_breaking or excluded.is_breaking,
    updated_at = now();

  return n;
end $$;

-- ---------- merge pass: heal fragmented clusters ----------
-- For each embedded recent article, find its nearest cross-cluster neighbour; a pair
-- closer than 0.25 means the two clusters tell one story — fold the younger-born
-- cluster into the older (stable id keeps first_seen honest for the velocity rule).
create or replace function public.merge_clusters() returns integer
language plpgsql security definer set search_path = public as $$
declare
  pair record; n integer := 0;
begin
  for pair in
    select distinct k.keep, k.dupe from (
      select case when ck.first_seen <= cd.first_seen then a1.cluster_id else nn.cluster_id end as keep,
             case when ck.first_seen <= cd.first_seen then nn.cluster_id else a1.cluster_id end as dupe
      from public.articles a1
      cross join lateral (
        select a2.cluster_id, a2.embedding <=> a1.embedding as d
        from public.articles a2
        where a2.embedding is not null and a2.cluster_id is not null
          and a2.cluster_id <> a1.cluster_id
          and a2.published_at > now() - interval '48 hours'
        order by a2.embedding <=> a1.embedding
        limit 1
      ) nn
      join public.clusters ck on ck.cluster_id = a1.cluster_id
      join public.clusters cd on cd.cluster_id = nn.cluster_id
      where a1.embedding is not null and a1.cluster_id is not null
        and a1.published_at > now() - interval '48 hours'
        and nn.d < 0.25
    ) k
    limit 25   -- bounded per run; the 15-min cron converges chains across runs
  loop
    update public.articles set cluster_id = pair.keep where cluster_id = pair.dupe;
    delete from public.clusters where cluster_id = pair.dupe;
    n := n + 1;
  end loop;
  return n;   -- stats refresh happens in the next assign_clusters upsert
end $$;

revoke execute on function public.assign_clusters() from public, anon, authenticated;
revoke execute on function public.merge_clusters() from public, anon, authenticated;

-- ---------- crons ----------
select cron.schedule('cluster_merge', '*/15 * * * *', $$select public.merge_clusters()$$);
-- Embeddings are a clustering-window resource, not an archive: prune to keep DB small.
select cron.schedule('embedding_prune', '40 3 * * *',
  $$update public.articles set embedding = null where embedding is not null and published_at < now() - interval '72 hours'$$);
