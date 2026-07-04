-- With "auto-expose new tables" disabled, service_role gets no default privileges either.
-- The ingest function (and only it) uses service_role; give it full access to public.
grant usage on schema public to service_role;
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
alter default privileges in schema public grant all on tables to service_role;
alter default privileges in schema public grant all on sequences to service_role;
