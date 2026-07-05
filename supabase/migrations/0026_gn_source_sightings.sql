-- Google News source census (the experiment's real payoff): every google-mode
-- fetch logs which publishers Google surfaced, so the top-N become candidates
-- for first-class corpus feeds — the hybrid fill shrinks until the toggle
-- retires. Writes only via the definer RPC; no anon table access.
create table if not exists public.gn_source_sightings (
  source_name text primary key,
  domain text,
  sightings bigint not null default 0,
  topics text[] not null default '{}',
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now()
);
alter table public.gn_source_sightings enable row level security;

create or replace function public.gn_log(entries jsonb)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if jsonb_typeof(entries) is distinct from 'array' or jsonb_array_length(entries) > 100 then
    return;
  end if;
  -- Pre-aggregate per source: one batch may carry the same name twice
  -- (a count entry + a domain-fill entry) and ON CONFLICT forbids that.
  insert into gn_source_sightings as t (source_name, domain, sightings, topics)
  select name, domain, n, topics
  from (
    select left(e->>'name', 120) as name,
           max(nullif(left(e->>'domain', 200), '')) as domain,
           least(sum(least(greatest(coalesce((e->>'n')::int, 1), 0), 60)), 120) as n,
           array_remove(array_agg(distinct nullif(left(e->>'topic', 60), '')), null) as topics
    from jsonb_array_elements(entries) e
    where coalesce(e->>'name', '') <> ''
    group by 1
  ) s
  on conflict (source_name) do update set
    sightings = t.sightings + excluded.sightings,
    domain = coalesce(t.domain, excluded.domain),
    topics = (select coalesce((array_agg(distinct x))[1:20], '{}'::text[])
              from unnest(t.topics || excluded.topics) x
              where x is not null),
    last_seen = now();
end $$;
revoke all on function public.gn_log(jsonb) from public;
grant execute on function public.gn_log(jsonb) to anon, authenticated;
