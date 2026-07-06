-- 0031_revert_entity_merge.sql
-- REVERT 0029's merge_clusters "pass 2" (entity-overlap + embedding<0.32). It over-merged
-- unrelated stories — catastrophically so once enrichment misaligned entities onto the wrong
-- articles (the 2026-07-06 "Lauren Bennett clustered with the World Cup" scramble): a football
-- headline carrying entities ["lauren bennett","lmfao"] shared >=2 "entities" with the singer's
-- obituary and merged. Back to embedding-only merging (0017's pass 1, d<0.12) which is safe.
-- Entity-aware merging can return later, but only once alignment is proven and with a much
-- tighter embedding guard.
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
        and ck.article_count + cd.article_count <= 30
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
