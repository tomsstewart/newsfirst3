-- AI overview: one daily Gemini call generates a short brief per preset topic.
create table public.briefs (
  topic      text not null,
  brief_date date not null default current_date,
  content    text not null,             -- 2-3 sentence AI overview of the topic's day
  created_at timestamptz not null default now(),
  primary key (topic, brief_date)
);
alter table public.briefs enable row level security;
create policy briefs_read on public.briefs for select using (true);
grant select on public.briefs to anon, authenticated;

select cron.schedule('daily_briefs', '45 6 * * *', $$select public.invoke_ingest('briefs')$$);
