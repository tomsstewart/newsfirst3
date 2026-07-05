-- Threshold recalibration from LIVE distance measurements (2026-07-05):
--   same-story pairs (Swift wedding cluster): 0.027-0.170, avg 0.090
--   unrelated cross-cluster pairs: p01=0.159, p05=0.196, MEDIAN=0.247
-- gte-small packs news titles into a narrow band — the initial 0.30/0.25 thresholds
-- sat ABOVE the unrelated median, and transitive merging chained a 189-article,
-- 45-source blob cluster (which also tripped the breaking flag). New rails:
--   assignment < 0.15, merge < 0.12, and merges never grow a cluster past 30 articles.

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

    if r.embedding is not null then
      select a.cluster_id into target
      from public.articles a
      where a.embedding is not null and a.cluster_id is not null
        and a.id <> r.id
        and a.published_at > now() - interval '36 hours'
        and a.source_id <> r.source_id
        and (a.embedding <=> r.embedding) < 0.15
      order by a.embedding <=> r.embedding
      limit 1;
    end if;

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
        and nn.d < 0.12
        and ck.article_count + cd.article_count <= 30   -- blob rail: stories don't hit 30 in 48h; chains do
    ) k
    limit 25
  loop
    update public.articles set cluster_id = pair.keep where cluster_id = pair.dupe;
    delete from public.clusters where cluster_id = pair.dupe;
    n := n + 1;
  end loop;
  return n;
end $$;

revoke execute on function public.assign_clusters() from public, anon, authenticated;
revoke execute on function public.merge_clusters() from public, anon, authenticated;

-- Repair: dissolve blob clusters born under the loose thresholds; strict assignment
-- re-clusters their members on the next passes.
update public.articles set cluster_id = null
  where cluster_id in (select cluster_id from public.clusters where article_count > 30);
delete from public.clusters where article_count > 30;

-- Re-arm the merge cron (was unscheduled during the incident).
select cron.schedule('cluster_merge', '*/15 * * * *', $$select public.merge_clusters()$$);
