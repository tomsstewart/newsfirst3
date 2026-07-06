-- Syndication-aware breaking (2026-07-06 High-band audit): Reach plc papers
-- (MEN / Liverpool Echo / WalesOnline) republish the SAME story minutes apart —
-- three "sources" of one editorial decision minted fake breaking clusters
-- ("Line of Duty fans won't be able to stop…" was a High-band alert candidate).
-- A syndicate chain counts as ONE source for the breaking calculation.

alter table public.sources add column if not exists syndication_group text;
update public.sources set syndication_group = 'reach'
 where name in ('Manchester Evening News','Liverpool Echo','WalesOnline');

create or replace function public.assign_clusters()
returns integer
language plpgsql security definer set search_path = public
as $$
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
    -- Independent corroboration: a syndicate chain collapses to one voice.
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
    updated_at = now();

  return n;
end $$;

-- Retro-clear: un-break clusters whose "3 sources" were one syndicate. is_breaking
-- is sticky by design, so recompute the flag for live clusters honestly once.
with g as (
  select cluster_id, min(published_at) as fs
  from public.articles
  where cluster_id is not null and published_at > now() - interval '48 hours'
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
update public.clusters c
set is_breaking = false, updated_at = now()
from early e
where c.cluster_id = e.cluster_id
  and c.is_breaking
  and e.esc < 3;
