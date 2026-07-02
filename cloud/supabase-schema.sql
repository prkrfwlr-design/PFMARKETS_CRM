-- ============================================================
-- Parker CRM · Supabase schema
-- Run this ONCE in your Supabase project: SQL Editor → New query
-- → paste everything → Run. Safe to re-run (idempotent).
-- ============================================================

create extension if not exists pgcrypto;

-- ---------- agency identity ----------
-- The email here becomes the AGENCY admin when it signs up.
create table if not exists public.agency_settings (
  id           boolean primary key default true check (id),
  agency_name  text not null default 'Parker',
  agency_email text not null
);
insert into public.agency_settings (agency_name, agency_email)
values ('Parker', 'prkrfwlr@gmail.com')
on conflict (id) do nothing;

-- ---------- core tables ----------
create table if not exists public.clients (
  id                 text primary key,
  business_name      text not null default '',
  industry           text not null default '',
  location           text not null default '',
  status             text not null default 'Prospect',
  services           text[] not null default '{}',
  contact_name       text not null default '',
  email              text not null default '',   -- client portal login email
  phone              text not null default '',
  website            text not null default '',
  monthly_retainer   numeric not null default 0,
  ad_budget_monthly  numeric not null default 0,
  billing_day        int not null default 1,
  start_date         date,
  renewal_date       date,
  accent             text not null default '#2e6b4f',
  notes              text not null default '',
  onboarding         jsonb not null default '{}'::jsonb,
  created_at         timestamptz not null default now()
);

create table if not exists public.leads (
  id            text primary key,
  client_id     text not null references public.clients(id) on delete cascade,
  name          text not null default '',
  email         text not null default '',
  phone         text not null default '',
  address       text not null default '',
  stage         text not null default 'New',
  source        text not null default '',
  job_type      text not null default '',
  quote_value   numeric not null default 0,
  date_received date,
  follow_up     date,
  notes         text not null default '',
  updated_at    timestamptz not null default now()
);

create table if not exists public.jobs (
  id         text primary key,
  client_id  text not null references public.clients(id) on delete cascade,
  title      text not null default '',
  customer   text not null default '',
  date       date,
  price      numeric not null default 0,
  status     text not null default 'Scheduled',
  address    text not null default '',
  notes      text not null default '',
  updated_at timestamptz not null default now()
);

create table if not exists public.quotes (
  id         text primary key,
  client_id  text not null references public.clients(id) on delete cascade,
  customer   text not null default '',
  service    text not null default '',
  amount     numeric not null default 0,
  status     text not null default 'Sent',
  date_sent  date,
  notes      text not null default '',
  updated_at timestamptz not null default now()
);

create table if not exists public.ads (
  id          text primary key,
  client_id   text not null references public.clients(id) on delete cascade,
  period      text not null default '',     -- YYYY-MM
  campaign    text not null default '',
  spend       numeric not null default 0,
  impressions numeric not null default 0,
  clicks      numeric not null default 0,
  leads       numeric not null default 0,
  sales       numeric not null default 0,
  revenue     numeric not null default 0
);

create table if not exists public.tasks (
  id         text primary key,
  client_id  text references public.clients(id) on delete set null,
  title      text not null default '',
  type       text not null default 'Optimization',
  due        date,
  recurring  text not null default 'None',
  status     text not null default 'To Do',
  notes      text not null default ''
);

create table if not exists public.invoices (
  id         text primary key,
  client_id  text not null references public.clients(id) on delete cascade,
  period     text not null default '',     -- YYYY-MM
  amount     numeric not null default 0,
  status     text not null default 'Due',
  date_paid  date
);

-- ---------- login profiles ----------
create table if not exists public.profiles (
  id        uuid primary key references auth.users(id) on delete cascade,
  email     text not null default '',
  role      text not null check (role in ('agency','client')),
  client_id text references public.clients(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists leads_client_idx    on public.leads(client_id);
create index if not exists jobs_client_idx     on public.jobs(client_id);
create index if not exists quotes_client_idx   on public.quotes(client_id);
create index if not exists ads_client_idx      on public.ads(client_id);
create index if not exists tasks_client_idx    on public.tasks(client_id);
create index if not exists invoices_client_idx on public.invoices(client_id);
create index if not exists profiles_client_idx on public.profiles(client_id);

-- ---------- helper functions (used by policies) ----------
create or replace function public.is_agency()
returns boolean language sql stable security definer set search_path = public as
$$ select exists (select 1 from profiles where id = auth.uid() and role = 'agency') $$;

create or replace function public.my_client_id()
returns text language sql stable security definer set search_path = public as
$$ select client_id from profiles where id = auth.uid() $$;

-- ---------- signup: link new logins automatically ----------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_client text;
begin
  if exists (select 1 from agency_settings where lower(agency_email) = lower(new.email)) then
    insert into profiles (id, email, role) values (new.id, new.email, 'agency')
    on conflict (id) do nothing;
  else
    select id into v_client from clients where lower(email) = lower(new.email) limit 1;
    insert into profiles (id, email, role, client_id) values (new.id, new.email, 'client', v_client)
    on conflict (id) do nothing;
  end if;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users for each row execute function public.handle_new_user();

-- If Parker adds/edits a client email AFTER that person already signed up, link them.
create or replace function public.link_client_logins()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update profiles set client_id = new.id
  where role = 'client' and client_id is null and lower(email) = lower(new.email) and new.email <> '';
  return new;
end $$;

drop trigger if exists clients_link_logins on public.clients;
create trigger clients_link_logins
after insert or update of email on public.clients
for each row execute function public.link_client_logins();

-- Clients edit their own branding through this (never the whole row —
-- retainer, status and notes stay agency-only).
create or replace function public.update_my_branding(p_name text, p_industry text, p_location text, p_accent text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update clients set
    business_name = coalesce(nullif(p_name, ''), business_name),
    industry = coalesce(p_industry, industry),
    location = coalesce(p_location, location),
    accent   = coalesce(nullif(p_accent, ''), accent)
  where id = (select client_id from profiles where id = auth.uid());
end $$;

-- ---------- row-level security ----------
alter table public.agency_settings enable row level security;
alter table public.clients   enable row level security;
alter table public.leads     enable row level security;
alter table public.jobs      enable row level security;
alter table public.quotes    enable row level security;
alter table public.ads       enable row level security;
alter table public.tasks     enable row level security;
alter table public.invoices  enable row level security;
alter table public.profiles  enable row level security;

-- agency settings: any signed-in user may read the agency name; only agency edits
drop policy if exists settings_read  on public.agency_settings;
drop policy if exists settings_write on public.agency_settings;
create policy settings_read  on public.agency_settings for select using (auth.uid() is not null);
create policy settings_write on public.agency_settings for update using (public.is_agency()) with check (public.is_agency());

-- profiles: you can see your own; agency sees all
drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select using (id = auth.uid() or public.is_agency());

-- clients: agency full control; a client can read their own record only
drop policy if exists clients_agency on public.clients;
drop policy if exists clients_self   on public.clients;
create policy clients_agency on public.clients for all    using (public.is_agency()) with check (public.is_agency());
create policy clients_self   on public.clients for select using (id = public.my_client_id());

-- leads / jobs / quotes: agency full control; client full control of their own rows
drop policy if exists leads_agency on public.leads;
drop policy if exists leads_self   on public.leads;
create policy leads_agency on public.leads for all using (public.is_agency()) with check (public.is_agency());
create policy leads_self   on public.leads for all using (client_id = public.my_client_id()) with check (client_id = public.my_client_id());

drop policy if exists jobs_agency on public.jobs;
drop policy if exists jobs_self   on public.jobs;
create policy jobs_agency on public.jobs for all using (public.is_agency()) with check (public.is_agency());
create policy jobs_self   on public.jobs for all using (client_id = public.my_client_id()) with check (client_id = public.my_client_id());

drop policy if exists quotes_agency on public.quotes;
drop policy if exists quotes_self   on public.quotes;
create policy quotes_agency on public.quotes for all using (public.is_agency()) with check (public.is_agency());
create policy quotes_self   on public.quotes for all using (client_id = public.my_client_id()) with check (client_id = public.my_client_id());

-- ads: agency writes, clients read their own (results are read-only for them)
drop policy if exists ads_agency on public.ads;
drop policy if exists ads_self   on public.ads;
create policy ads_agency on public.ads for all    using (public.is_agency()) with check (public.is_agency());
create policy ads_self   on public.ads for select using (client_id = public.my_client_id());

-- tasks & invoices: agency only
drop policy if exists tasks_agency on public.tasks;
create policy tasks_agency on public.tasks for all using (public.is_agency()) with check (public.is_agency());

drop policy if exists invoices_agency on public.invoices;
create policy invoices_agency on public.invoices for all using (public.is_agency()) with check (public.is_agency());
