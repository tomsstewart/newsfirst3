-- The 0017 blob rail read clusters.article_count — STALE mid-run (stats refresh only
-- in assign_clusters), so chained merges inside one call rebuilt a 189-article blob.
-- v3: live counts from articles, and each cluster participates in at most one merge
-- per call, so a cluster grows by one partner per 15-min cycle at most.

create or replace function public.merge_clusters() returns integer
language plpgsql security definer set search_path = public as $$
declare
  pair record; n integer := 0; touched uuid[] := '{}';
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
        -- live counts — the clusters table lags mid-run
        and (select count(*) from public.articles x where x.cluster_id = a1.cluster_id)
          + (select count(*) from public.articles y where y.cluster_id = nn.cluster_id) <= 30
    ) k
    limit 25
  loop
    if pair.keep = any(touched) or pair.dupe = any(touched) then continue; end if;
    touched := touched || pair.keep || pair.dupe;
    update public.articles set cluster_id = pair.keep where cluster_id = pair.dupe;
    delete from public.clusters where cluster_id = pair.dupe;
    n := n + 1;
  end loop;
  return n;
end $$;

revoke execute on function public.merge_clusters() from public, anon, authenticated;

-- Repair round two: dissolve anything the stale rail let through, by LIVE count.
update public.articles set cluster_id = null
  where cluster_id in (select cluster_id from public.articles where cluster_id is not null
                       group by cluster_id having count(*) > 30);
delete from public.clusters c
  where not exists (select 1 from public.articles a where a.cluster_id = c.cluster_id);
