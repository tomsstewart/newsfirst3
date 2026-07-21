-- 2026-07-21 outage repeat: the clustering jobs outgrew the instance. assign_clusters
-- (400/tick, trigram fallback via similarity() = un-indexed seq scan per unembedded
-- article), merge_clusters (HNSW probe per EVERY 48h article, every 15 min) and
-- refresh_cluster_labels (regexp over every 48h title + full clusters rewrite every
-- 10 min) each ran past the 2-min cron statement_timeout, retried forever at 100%
-- wasted work, drained burst credits, and starved refresh_feed_mat + everything else
-- ("job startup timeout") — same live-lock as 2026-07-20, different driver.
--
-- Principles (the once-and-for-all part):
--   1. Every recurring job does BOUNDED work per tick (small batch, active-set only).
--   2. Heavy loops are TIME-BOXED with clock_timestamp() so they commit partial
--      progress instead of being cancelled and retried from scratch.
--   3. Every hot query is INDEX-SHAPED: pure-ANN top-K probes for pgvector, `%`
--      operator (not similarity()) for pg_trgm, && for entity arrays.
--   4. No-op writes are skipped (label churn = WAL + matview-diff churn).
--   5. Each cron command carries its own statement_timeout so a sick run dies fast
--      and frees its worker.

-- ---------- 0. unstick: cancel any currently-running heavy jobs ----------
select pg_cancel_backend(pid)
from pg_stat_activity
where pid <> pg_backend_pid()
  and state = 'active'
  and (query ilike '%assign_clusters%'
    or query ilike '%merge_clusters%'
    or query ilike '%refresh_cluster_labels%'
    or query ilike '%refresh_tier_thresholds%');

-- ---------- 1. assign_clusters: bounded batch, index-shaped probes, time-boxed ----------
create or replace function public.assign_clusters() returns integer
language plpgsql security definer set search_path = public as $$
declare
  r record; target uuid; n integer := 0;
  deadline timestamptz := clock_timestamp() + interval '50 seconds';
begin
  -- Trigram fallback below uses `title % r.title` so the gin_trgm index applies.
  perform set_config('pg_trgm.similarity_threshold', '0.6', true);

  for r in
    select id, title, entities, source_id, embedding from public.articles
    where cluster_id is null and published_at > now() - interval '36 hours'
    order by published_at asc limit 150
  loop
    exit when clock_timestamp() > deadline;
    target := null;

    if r.embedding is not null then
      -- Pure-ANN top-K from the partial HNSW index, THEN filter. Embeddings only
      -- exist ≤72h (embedding_prune), so no time filter is needed inside the probe.
      -- Diameter guard unchanged: a blob with any member farther than 0.13 is
      -- rejected even if one member happens to be close.
      select t.cluster_id into target
      from (
        select a.id, a.cluster_id, a.source_id,
               (a.embedding <=> r.embedding) as d
        from public.articles a
        where a.embedding is not null
        order by a.embedding <=> r.embedding
        limit 12
      ) t
      where t.d < 0.10
        and t.id <> r.id
        and t.source_id <> r.source_id
        and t.cluster_id is not null
        and not exists (
          select 1 from public.articles m
          where m.cluster_id = t.cluster_id
            and m.embedding is not null
            and (m.embedding <=> r.embedding) > 0.13
        )
      order by t.d
      limit 1;
    end if;

    if target is null then
      -- Fallback for articles without embeddings: strong title (% = trgm index)
      -- or entity overlap (&& = gin index) only.
      select a.cluster_id into target
      from public.articles a
      where a.id <> r.id
        and a.cluster_id is not null
        and a.published_at > now() - interval '36 hours'
        and a.source_id <> r.source_id
        and ( a.title % r.title
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

  -- Stats upsert bounded to clusters with recent activity (anything this batch
  -- touched has an article inside 36h by construction).
  with recent as (
    select distinct cluster_id from public.articles
    where cluster_id is not null and published_at > now() - interval '36 hours'
  ), g as (
    select a.cluster_id, min(a.published_at) as fs,
           count(distinct a.source_id) as sc, count(*) as ac
    from public.articles a
    join recent using (cluster_id)
    where a.published_at > now() - interval '48 hours'
    group by 1
  ), early as (
    select a.cluster_id,
           count(distinct coalesce(s.syndication_group, a.source_id::text)) as esc
    from public.articles a
    join public.sources s on s.id = a.source_id
    join g on g.cluster_id = a.cluster_id
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
    updated_at = now()
  where clusters.source_count is distinct from excluded.source_count
     or clusters.article_count is distinct from excluded.article_count
     or (excluded.is_breaking and not clusters.is_breaking);

  return n;
end $$;
revoke execute on function public.assign_clusters() from public, anon, authenticated;

-- ---------- 2. merge_clusters: probe only NEW arrivals, not every 48h article ----------
-- Older articles were already probed for merges when they were new; re-probing the
-- whole window every tick is what made this O(N * ANN) at ~10k articles/day.
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
        and a1.published_at > now() - interval '3 hours'   -- was 48 hours: only new arrivals
        and nn.d < 0.08                                    -- only near-duplicate splits
        and ck.article_count + cd.article_count <= 25
        and not exists (                                   -- diameter guard on the merge
          select 1 from public.articles x
          join public.articles y on y.cluster_id = nn.cluster_id
          where x.cluster_id = a1.cluster_id
            and x.embedding is not null and y.embedding is not null
            and (x.embedding <=> y.embedding) > 0.13
        )
    ) k
    limit 25
  loop
    update public.articles set cluster_id = pair.keep where cluster_id = pair.dupe;
    delete from public.clusters where cluster_id = pair.dupe;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.merge_clusters() from public, anon, authenticated;

-- ---------- 3. refresh_cluster_labels: active clusters only, skip no-op writes ----------
create or replace function public.refresh_cluster_labels() returns void
language sql security definer set search_path = public as $$
  with active as (
    select cluster_id from public.clusters
    where updated_at > now() - interval '30 minutes'
  ),
  toks as (
    select a.cluster_id, (regexp_matches(a.title, '([A-Z][A-Za-z][A-Za-z]+)', 'g'))[1] as w
    from public.articles a
    join active using (cluster_id)
    where a.published_at > now() - interval '48 hours'
  ),
  ranked as (
    select cluster_id, w, count(*) c,
           row_number() over (partition by cluster_id order by count(*) desc, w) rn
    from toks
    where w not in ('The','This','That','These','Those','After','Before','Why','How','What',
                    'When','Where','Who','New','And','For','With','From','Live','News','Update',
                    'Updates','Says','Said','Amid','Over','Into','Your','Will','Has','Have','Are',
                    'Was','But','Not','Its','His','Her','They','Their','Watch','Video','Here')
    group by cluster_id, w
  )
  update public.clusters cl
  set label = case when r.c >= 2 then r.w else null end
  from (select cluster_id, w, c from ranked where rn = 1) r
  where cl.cluster_id = r.cluster_id
    and cl.label is distinct from (case when r.c >= 2 then r.w else null end);
$$;
revoke execute on function public.refresh_cluster_labels() from public, anon, authenticated;

-- ---------- 4. reschedule with per-job timeouts (cron.schedule upserts by name) ----------
select cron.schedule('cluster_tick', '*/5 * * * *',
  $$set statement_timeout = '90s'; select public.assign_clusters()$$);
select cron.schedule('cluster_merge', '*/30 * * * *',
  $$set statement_timeout = '90s'; select public.merge_clusters()$$);
select cron.schedule('cluster_labels', '3-59/10 * * * *',
  $$set statement_timeout = '60s'; select public.refresh_cluster_labels()$$);
select cron.schedule('tier_thresholds_hourly', '12 * * * *',
  $$set statement_timeout = '90s'; select public.refresh_tier_thresholds()$$);
