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

-- ============================================================
-- EMPLOYEE LAYER
-- Employees do the client work; clients never see them, and
-- employees never see agency business data (retainers, invoices,
-- private notes). Enforced here, not in the UI.
-- ============================================================

-- ---------- employee tables ----------
create table if not exists public.employees (
  id         text primary key,
  name       text not null default '',
  email      text not null default '',   -- employee portal login email
  phone      text not null default '',
  role_title text not null default '',
  status     text not null default 'Active',    -- Active / Paused / Terminated
  pay_type   text not null default 'Hourly',    -- Hourly / Salary
  pay_rate   numeric not null default 0,        -- $/hr, or $ per pay period if Salary
  hire_date  date,
  notes      text not null default '',
  created_at timestamptz not null default now()
);

-- live clock in/out; an open shift has clock_out = null
create table if not exists public.time_entries (
  id          text primary key,
  employee_id text not null references public.employees(id) on delete cascade,
  clock_in    timestamptz not null default now(),
  clock_out   timestamptz,
  note        text not null default '',
  hours       numeric generated always as
              (round((extract(epoch from (clock_out - clock_in)) / 3600.0)::numeric, 2)) stored
);

create table if not exists public.assignments (
  id          text primary key,
  employee_id text not null references public.employees(id) on delete cascade,
  client_id   text references public.clients(id) on delete cascade,
  title       text not null default '',
  detail      text not null default '',
  due         date,
  priority    text not null default 'Normal',   -- Low / Normal / High
  status      text not null default 'To Do',    -- To Do / In Progress / Blocked / Done
  origin      text not null default 'agency',   -- 'agency' = assigned by Parker, 'self' = employee added it
  locked      boolean not null default false,   -- locked rows: employee may only advance status (via RPC)
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table if not exists public.pay_periods (
  id           text primary key,
  employee_id  text not null references public.employees(id) on delete cascade,
  period_start date,
  period_end   date,
  hours        numeric not null default 0,
  gross_amount numeric not null default 0,
  status       text not null default 'Pending', -- Pending / Paid
  date_paid    date,
  notes        text not null default ''
);

-- profiles: allow the employee role and link column
alter table public.profiles add column if not exists employee_id text references public.employees(id) on delete set null;
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('agency','client','employee'));

create index if not exists time_entries_employee_idx on public.time_entries(employee_id);
create index if not exists assignments_employee_idx  on public.assignments(employee_id);
create index if not exists assignments_client_idx    on public.assignments(client_id);
create index if not exists pay_periods_employee_idx  on public.pay_periods(employee_id);
create index if not exists profiles_employee_idx     on public.profiles(employee_id);

-- ---------- helper ----------
create or replace function public.my_employee_id()
returns text language sql stable security definer set search_path = public as
$$ select employee_id from profiles where id = auth.uid() $$;

-- ---------- signup: link employee logins too ----------
-- Order matters: agency email first, then employees, then clients.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_client text; v_employee text;
begin
  if exists (select 1 from agency_settings where lower(agency_email) = lower(new.email)) then
    insert into profiles (id, email, role) values (new.id, new.email, 'agency')
    on conflict (id) do nothing;
  else
    select id into v_employee from employees where lower(email) = lower(new.email) limit 1;
    if v_employee is not null then
      insert into profiles (id, email, role, employee_id) values (new.id, new.email, 'employee', v_employee)
      on conflict (id) do nothing;
    else
      select id into v_client from clients where lower(email) = lower(new.email) limit 1;
      insert into profiles (id, email, role, client_id) values (new.id, new.email, 'client', v_client)
      on conflict (id) do nothing;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users for each row execute function public.handle_new_user();

-- If Parker adds/edits an employee email AFTER that person already signed up, link them.
create or replace function public.link_employee_logins()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update profiles set role = 'employee', employee_id = new.id, client_id = null
  where role <> 'agency' and employee_id is null and client_id is null
    and lower(email) = lower(new.email) and new.email <> '';
  return new;
end $$;

drop trigger if exists employees_link_logins on public.employees;
create trigger employees_link_logins
after insert or update of email on public.employees
for each row execute function public.link_employee_logins();

-- Employees edit their own contact info through this (never the whole row —
-- pay_rate, pay_type, status and notes stay agency-only).
create or replace function public.update_my_employee_profile(p_name text, p_phone text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update employees set
    name  = coalesce(nullif(p_name, ''), name),
    phone = coalesce(p_phone, phone)
  where id = public.my_employee_id();
end $$;

-- Employees advance status on ANY of their assignments (including locked ones)
-- through this — status only, never title/detail/due/client/reassignment.
create or replace function public.set_my_assignment_status(p_id text, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_status not in ('To Do','In Progress','Blocked','Done') then
    raise exception 'invalid status';
  end if;
  update assignments set status = p_status, updated_at = now()
  where id = p_id and employee_id = public.my_employee_id();
end $$;

-- Clients this employee has been GIVEN by the agency (origin 'agency' only,
-- so an employee can't self-grant access by inserting their own assignment).
-- Security definer: also used inside assignments policies without recursion.
create or replace function public.my_agency_client_ids()
returns setof text language sql stable security definer set search_path = public as
$$ select distinct client_id from assignments
   where employee_id = public.my_employee_id() and origin = 'agency' and client_id is not null $$;

-- The client context an employee is allowed to see for their assigned clients:
-- identity and branding only — never retainer, ad budget, billing or notes.
create or replace function public.my_assignment_clients()
returns table (id text, business_name text, industry text, location text, website text, accent text)
language sql stable security definer set search_path = public as
$$ select c.id, c.business_name, c.industry, c.location, c.website, c.accent
   from clients c
   where c.id in (select public.my_agency_client_ids()) $$;

-- ---------- row-level security: the privacy wall ----------
-- Clients match no policy on any employee table (my_employee_id() is null
-- for them), so employee, assignment, time and pay data is invisible to them.
-- Employees match no client-table policy (my_client_id() is null for them),
-- so retainers, invoices, ad budgets and private notes are invisible to them.
alter table public.employees    enable row level security;
alter table public.time_entries enable row level security;
alter table public.assignments  enable row level security;
alter table public.pay_periods  enable row level security;

-- employees: agency full control; an employee can read their own record only
-- (contact edits go through update_my_employee_profile — pay fields stay agency-only)
drop policy if exists employees_agency on public.employees;
drop policy if exists employees_self   on public.employees;
create policy employees_agency on public.employees for all    using (public.is_agency()) with check (public.is_agency());
create policy employees_self   on public.employees for select using (id = public.my_employee_id());

-- time entries: agency full control; employee reads their own, clocks in
-- (open entries only), and can correct/close/delete an entry only while it is open
drop policy if exists time_agency      on public.time_entries;
drop policy if exists time_self_read   on public.time_entries;
drop policy if exists time_self_insert on public.time_entries;
drop policy if exists time_self_update on public.time_entries;
drop policy if exists time_self_delete on public.time_entries;
create policy time_agency      on public.time_entries for all    using (public.is_agency()) with check (public.is_agency());
create policy time_self_read   on public.time_entries for select using (employee_id = public.my_employee_id());
create policy time_self_insert on public.time_entries for insert with check (employee_id = public.my_employee_id() and clock_out is null);
create policy time_self_update on public.time_entries for update using (employee_id = public.my_employee_id() and clock_out is null) with check (employee_id = public.my_employee_id());
create policy time_self_delete on public.time_entries for delete using (employee_id = public.my_employee_id() and clock_out is null);

-- assignments: agency full control; employee reads their own, adds their own
-- (origin 'self', never locked), and edits/deletes only their own unlocked
-- self-added ones. Status changes on locked rows go through set_my_assignment_status.
drop policy if exists assign_agency      on public.assignments;
drop policy if exists assign_self_read   on public.assignments;
drop policy if exists assign_self_insert on public.assignments;
drop policy if exists assign_self_update on public.assignments;
drop policy if exists assign_self_delete on public.assignments;
create policy assign_agency      on public.assignments for all    using (public.is_agency()) with check (public.is_agency());
create policy assign_self_read   on public.assignments for select using (employee_id = public.my_employee_id());
create policy assign_self_insert on public.assignments for insert with check (employee_id = public.my_employee_id() and origin = 'self' and locked = false and (client_id is null or client_id in (select public.my_agency_client_ids())));
create policy assign_self_update on public.assignments for update using (employee_id = public.my_employee_id() and origin = 'self' and locked = false) with check (employee_id = public.my_employee_id() and origin = 'self' and locked = false and (client_id is null or client_id in (select public.my_agency_client_ids())));
create policy assign_self_delete on public.assignments for delete using (employee_id = public.my_employee_id() and origin = 'self' and locked = false);

-- pay periods: agency posts pay; employee read-only on their own
drop policy if exists pay_agency on public.pay_periods;
drop policy if exists pay_self   on public.pay_periods;
create policy pay_agency on public.pay_periods for all    using (public.is_agency()) with check (public.is_agency());
create policy pay_self   on public.pay_periods for select using (employee_id = public.my_employee_id());

-- ============================================================
-- EMAIL CAMPAIGNS MODULE
-- Cold/nurture email tracking per client. Aggregate stats (sends,
-- opens, replies, meetings) are entered manually from GMass — no
-- live send integration yet. Gated behind a per-client feature flag
-- so clients only see this tab once Parker turns it on for them.
-- ============================================================

-- ---------- feature flag ----------
alter table public.clients add column if not exists email_marketing_enabled boolean not null default false;

-- ---------- tables ----------
create table if not exists public.email_campaigns (
  id               text primary key,
  client_id        text not null references public.clients(id) on delete cascade,
  name             text not null default '',
  status           text not null default 'Draft',   -- Draft / Active / Paused / Done
  emails_sent      int not null default 0,
  opens            int not null default 0,
  replies          int not null default 0,
  meetings_booked  int not null default 0,
  started_at       date,
  notes            text not null default '',
  created_at       timestamptz not null default now()
);

create table if not exists public.email_contacts (
  id             text primary key,
  client_id      text not null references public.clients(id) on delete cascade,
  campaign_id    text references public.email_campaigns(id) on delete set null,
  name           text not null default '',
  email          text not null default '',
  company        text not null default '',
  phone          text not null default '',
  status         text not null default 'Lead',   -- Lead / Contacted / Replied / Needs Follow-up / Closed Won / Closed Lost
  last_contacted date,
  next_touch     date,
  notes          text not null default '',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

alter table public.email_contacts drop constraint if exists email_contacts_status_check;
alter table public.email_contacts add constraint email_contacts_status_check
  check (status in ('Lead','Contacted','Replied','Needs Follow-up','Closed Won','Closed Lost'));

create index if not exists email_campaigns_client_idx   on public.email_campaigns(client_id);
create index if not exists email_contacts_client_idx    on public.email_contacts(client_id);
create index if not exists email_contacts_campaign_idx  on public.email_contacts(campaign_id);

-- ---------- helper: is email marketing turned on for MY client? ----------
create or replace function public.my_email_marketing_enabled()
returns boolean language sql stable security definer set search_path = public as
$$ select coalesce((select email_marketing_enabled from clients where id = public.my_client_id()), false) $$;

-- ---------- row-level security ----------
alter table public.email_campaigns enable row level security;
alter table public.email_contacts  enable row level security;

-- email_campaigns: agency full control; client read-only on their own rows,
-- and only while Parker has switched email_marketing_enabled on for them
drop policy if exists email_campaigns_agency on public.email_campaigns;
drop policy if exists email_campaigns_self   on public.email_campaigns;
create policy email_campaigns_agency on public.email_campaigns for all    using (public.is_agency()) with check (public.is_agency());
create policy email_campaigns_self   on public.email_campaigns for select using (client_id = public.my_client_id() and public.my_email_marketing_enabled());

-- email_contacts: same shape — agency full control; client read-only, gated by the flag
drop policy if exists email_contacts_agency on public.email_contacts;
drop policy if exists email_contacts_self   on public.email_contacts;
create policy email_contacts_agency on public.email_contacts for all    using (public.is_agency()) with check (public.is_agency());
create policy email_contacts_self   on public.email_contacts for select using (client_id = public.my_client_id() and public.my_email_marketing_enabled());

-- Employees: no policy on either table. my_employee_id() plays no part in
-- these policies, so employee logins match neither the agency clause (not
-- agency role) nor the client clause (client_id is null for them) — the
-- tables are invisible to them by default, same as invoices/retainers.

-- ============================================================
-- GMASS SYNC MODULE
-- Automated pull of live campaign stats + per-recipient activity
-- from GMass into email_campaigns / email_contacts, via the
-- 'gmass-sync' edge function. A row syncs only once Parker fills in
-- its GMass Campaign ID (agency.html). An hourly pg_cron job invokes
-- the function server-side; the function uses the service role to
-- write, so it bypasses RLS. See edge/SETUP-GMASS-SYNC.md.
-- ============================================================

-- ---------- link + audit columns on email_campaigns ----------
alter table public.email_campaigns add column if not exists gmass_campaign_id text;
alter table public.email_campaigns add column if not exists last_synced_at    timestamptz;

-- ---------- hourly schedule (pg_cron + pg_net) ----------
-- Requires the pg_cron and pg_net extensions (enable them under
-- Database → Extensions in the Supabase Dashboard, or below).
-- PARKER: fill in <PROJECT_REF> and <SYNC_TRIGGER_KEY> before running
-- this block. Both must match what you set in the edge function's
-- secrets. The service role is NOT needed here — the function accepts
-- the x-sync-key header for cron triggers.
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Re-runnable: drop the existing schedule (if any) before re-adding it,
-- so pasting this file twice never creates duplicate jobs.
do $$
begin
  if exists (select 1 from cron.job where jobname = 'gmass-sync-hourly') then
    perform cron.unschedule('gmass-sync-hourly');
  end if;
end $$;

select cron.schedule(
  'gmass-sync-hourly',
  '0 * * * *',                       -- top of every hour
  $$
  select net.http_post(
    url     := 'https://<PROJECT_REF>.supabase.co/functions/v1/gmass-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-sync-key',   '<SYNC_TRIGGER_KEY>'
    ),
    body    := '{}'::jsonb
  );
  $$
);
