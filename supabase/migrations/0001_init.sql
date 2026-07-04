-- NewsFirst v3 — initial schema
-- Principles: slim immutable articles; priority computed at READ time (zero-write decay);
-- explicit grants (tables are not auto-exposed); RLS everywhere; service role writes only from the ingest worker.

-- ============ SOURCES ============
create table public.sources (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  feed_url      text not null unique,
  home_url      text,
  category      text not null default 'general',
  weight        smallint not null default 3 check (weight between 1 and 5),
  region        text,                          -- ISO 3166-1 alpha-2 of the source's home audience
  -- conditional-GET state
  etag          text,
  last_modified text,
  -- health (backoff, never silent death)
  last_fetch_at    timestamptz,
  last_success_at  timestamptz,
  last_new_item_at timestamptz,
  fail_streak      int not null default 0,
  backoff_until    timestamptz,
  health           text not null default 'ok' check (health in ('ok','degraded','broken')),
  is_enabled       boolean not null default true,
  poll_interval_s  int not null default 600,   -- adaptive: shrinks for busy feeds, grows for quiet ones
  meta          jsonb not null default '{}',
  created_at    timestamptz not null default now()
);

-- ============ ARTICLES (slim + immutable scoring) ============
create table public.articles (
  id            uuid primary key default gen_random_uuid(),
  url           text not null,
  url_hash      text not null unique,          -- sha256 of normalised url
  title         text not null,
  excerpt       text,                          -- capped at ingest (~500 chars)
  image_url     text,
  image_status  text not null default 'unchecked' check (image_status in ('ok','bad','none','unchecked')),
  source_id     uuid not null references public.sources(id),
  published_at  timestamptz not null,          -- NEVER null: worker falls back to first_seen_at
  first_seen_at timestamptz not null default now(),
  lang          text,
  topics        text[] not null default '{}',  -- AI-enriched topic slugs
  entities      text[] not null default '{}',  -- AI-extracted entities (lowercased)
  regions       text[] not null default '{}',  -- AI-extracted country codes
  cluster_id    uuid,                          -- story cluster (breaking-news velocity)
  base_score    smallint not null default 0,   -- written ONCE at ingest; never updated
  score_breakdown jsonb                        -- kept server-side; not selected by clients
);

create index articles_published_idx on public.articles (published_at desc);
create index articles_topics_idx    on public.articles using gin (topics);
create index articles_cluster_idx   on public.articles (cluster_id) where cluster_id is not null;
create index articles_source_idx    on public.articles (source_id, published_at desc);

-- ============ READ-TIME PRIORITY (the v2 decay bug class, made impossible) ============
-- effective score = base_score * time multiplier; monotonic decay, no writes, no stale labels.
create or replace function public.effective_score(base smallint, published timestamptz, at timestamptz default now())
returns numeric
language sql immutable parallel safe
as $$
  select round(base * case
    when at - published < interval '90 minutes' then 2.0
    when at - published < interval '3 hours'    then 1.5
    when at - published < interval '24 hours'   then 1.0 - 0.5 * extract(epoch from (at - published) - interval '3 hours') / extract(epoch from interval '21 hours')
    when at - published < interval '48 hours'   then 0.5 - 0.49 * extract(epoch from (at - published) - interval '24 hours') / extract(epoch from interval '24 hours')
    else 0.01
  end, 2)
$$;

create or replace function public.priority_tier(base smallint, published timestamptz, at timestamptz default now())
returns text
language sql immutable parallel safe
as $$
  select case
    when public.effective_score(base, published, at) > 70 then 'high'
    when public.effective_score(base, published, at) > 40 then 'medium'
    else 'low'
  end
$$;

-- ============ USERS ============
create table public.profiles (
  id         uuid primary key references auth.users (id) on delete cascade,
  country    text,                              -- from device locale at onboarding
  plan       text not null default 'free' check (plan in ('free','pro')),
  created_at timestamptz not null default now()
);

-- Preset topics and custom keyword topics unified.
-- notify_level is the core product control: none | high (high-priority only) | all (every match).
create table public.topic_subscriptions (
  user_id      uuid not null references auth.users (id) on delete cascade,
  topic        text not null,                   -- preset slug ('tech') or custom phrase ('rare earth')
  kind         text not null default 'preset' check (kind in ('preset','custom')),
  notify_level text not null default 'none' check (notify_level in ('none','high','all')),
  sort_order   smallint not null default 0,
  created_at   timestamptz not null default now(),
  primary key (user_id, topic)
);

create table public.devices (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  apns_token  text not null unique,
  environment text not null default 'prod' check (environment in ('prod','sandbox')),
  is_valid    boolean not null default true,    -- flipped false on APNs 410/BadDeviceToken; pruned
  last_seen_at timestamptz not null default now(),
  created_at  timestamptz not null default now()
);
create index devices_user_idx on public.devices (user_id);

create table public.notification_settings (
  user_id     uuid primary key references auth.users (id) on delete cascade,
  daily_cap   smallint not null default 30,
  quiet_start smallint check (quiet_start between 0 and 1439),  -- minutes from local midnight
  quiet_end   smallint check (quiet_end between 0 and 1439),
  tz          text not null default 'UTC',
  digest_hour smallint not null default 8 check (digest_hour between 0 and 23),
  updated_at  timestamptz not null default now()
);

-- ============ ALERTS (send → deliver → open, finally measurable) ============
create table public.alerts (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users (id) on delete cascade,
  article_id   uuid references public.articles (id) on delete set null,
  topic        text not null,
  kind         text not null check (kind in ('instant','digest','breaking')),
  sent_at      timestamptz not null default now(),
  delivered_at timestamptz,                     -- set from APNs response/receipt path
  opened_at    timestamptz,                     -- set by client on open
  apns_id      text
);
create index alerts_user_idx on public.alerts (user_id, sent_at desc);

-- ============ FEED HEALTH / OPS ============
create table public.ingest_runs (
  id                bigint generated always as identity primary key,
  started_at        timestamptz not null default now(),
  finished_at       timestamptz,
  sources_polled    int not null default 0,
  sources_failed    int not null default 0,
  articles_inserted int not null default 0,
  notes             jsonb not null default '{}'
);

-- ============ RLS ============
-- (project has auto-RLS on new tables; enable explicitly anyway for determinism)
alter table public.sources               enable row level security;
alter table public.articles              enable row level security;
alter table public.profiles              enable row level security;
alter table public.topic_subscriptions   enable row level security;
alter table public.devices               enable row level security;
alter table public.notification_settings enable row level security;
alter table public.alerts                enable row level security;
alter table public.ingest_runs           enable row level security;

-- Public content: readable by everyone (guest feed is 5.1.1 compliance)
create policy sources_read  on public.sources  for select using (is_enabled);
create policy articles_read on public.articles for select using (true);

-- User-owned rows
create policy profiles_own  on public.profiles              for all using (auth.uid() = id)      with check (auth.uid() = id);
create policy topics_own    on public.topic_subscriptions   for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy devices_own   on public.devices               for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy notif_own     on public.notification_settings for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy alerts_read_own   on public.alerts for select using (auth.uid() = user_id);
create policy alerts_open_own   on public.alerts for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
-- ingest_runs: no client policies — service role only (dashboard reads via service key)

-- ============ EXPLICIT GRANTS (tables are not auto-exposed by this project's config) ============
grant select on public.sources, public.articles to anon, authenticated;
grant select, insert, update, delete on public.profiles, public.topic_subscriptions, public.devices, public.notification_settings to authenticated;
grant select, update on public.alerts to authenticated;
grant execute on function public.effective_score(smallint, timestamptz, timestamptz), public.priority_tier(smallint, timestamptz, timestamptz) to anon, authenticated;

-- Free-tier guardrail: max 3 custom topics unless pro (enforced server-side, not just UI)
create or replace function public.enforce_custom_topic_limit()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare n int; user_plan text;
begin
  if new.kind = 'custom' then
    select plan into user_plan from public.profiles where id = new.user_id;
    select count(*) into n from public.topic_subscriptions where user_id = new.user_id and kind = 'custom';
    if coalesce(user_plan, 'free') = 'free' and n >= 3 then
      raise exception 'free plan allows up to 3 custom topics' using errcode = 'P0001';
    end if;
  end if;
  return new;
end $$;

create trigger custom_topic_limit before insert on public.topic_subscriptions
  for each row execute function public.enforce_custom_topic_limit();

-- Auto-create profile + notification settings on signup
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles (id) values (new.id) on conflict do nothing;
  insert into public.notification_settings (user_id) values (new.id) on conflict do nothing;
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- 90-day retention (real scheduled job, not buried in ingest)
create or replace function public.purge_old_articles()
returns int
language plpgsql security definer set search_path = public
as $$
declare n int;
begin
  delete from public.articles where published_at < now() - interval '90 days';
  get diagnostics n = row_count;
  return n;
end $$;
