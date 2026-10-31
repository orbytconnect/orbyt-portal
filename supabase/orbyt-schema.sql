-- =====================================================================
-- Orbyt portal database
-- Run once in Supabase: SQL Editor > New query > paste all > Run.
-- Safe to run again: it skips what already exists and refreshes the rules.
--
-- Who sees what (enforced by row-level security):
--   Admin (Ashleigh): everything.
--   Agents: projects they own or that are shared with them, the bids on
--     those projects, and the vendors introduced to them.
--   Vendors: their own profile and only their own bids, plus the basic
--     details of projects they were introduced to. Never other vendors'
--     bids, prices, clients or budgets.
--   Clients (sellers and buyers): no login. A private link shows one
--     read-only quote page through client_quotes().
-- Private business data (invoices, notes, time, spend, contacts) is
-- admin only.
-- =====================================================================

-- ---------- helpers that the rules use ----------------------------------
create or replace function public.jsonb_text_array(j jsonb)
returns text[] language sql immutable set search_path = '' as $$
  select coalesce(array(select jsonb_array_elements_text(
    case when jsonb_typeof(j) = 'array' then j else '[]'::jsonb end)), '{}'::text[])
$$;

-- ---------- people ----------------------------------------------------------
create table if not exists public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  role        text not null default 'agent' check (role in ('admin', 'agent', 'vendor')),
  status      text not null default 'pending' check (status in ('pending', 'active', 'declined')),
  full_name   text,
  email       text,
  phone       text,
  brokerage   text,
  areas       text[] not null default '{}',
  created_at  timestamptz not null default now(),
  approved_at timestamptz
);

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role = 'admin' and status = 'active')
$$;

create or replace function public.is_active()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles where id = auth.uid() and status = 'active')
$$;

create or replace function public.my_email()
returns text language sql stable set search_path = '' as $$
  select lower(coalesce(auth.jwt() ->> 'email', ''))
$$;

-- ---------- vendors ---------------------------------------------------------
-- vendors: what the vendor manages and agents may see
create table if not exists public.vendors (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid unique references auth.users (id) on delete set null,
  name              text not null,
  contact_name      text,
  email             text,
  phone             text,
  website           text,
  services          text[] not null default '{}',
  areas             text[] not null default '{}',
  area_note         text,
  years_in_business text,
  team_size         text,
  lead_time         text,
  works_with_agents text,
  portfolio_url     text,
  photo_paths       text[] not null default '{}',
  available         boolean not null default true,
  source            text,
  created_at        timestamptz not null default now()
);
-- vendor_admin: set only by Ashleigh (approval, promo, credentials)
create table if not exists public.vendor_admin (
  vendor_id    uuid primary key references public.vendors (id) on delete cascade,
  approved     boolean not null default false,
  featured     boolean not null default false,
  licensed     boolean not null default false,
  insured      boolean not null default false,
  repeat_jobs  integer not null default 0,
  approved_at  timestamptz
);
-- vendor_private: sign-up answers only the vendor and Ashleigh see
create table if not exists public.vendor_private (
  vendor_id        uuid primary key references public.vendors (id) on delete cascade,
  references_text  text,
  heard_about      text,
  signup_notes     text,
  promo_interest   text,
  insurance_paths  text[] not null default '{}'
);
-- vendor_notes: Ashleigh's private notes
create table if not exists public.vendor_notes (
  id          uuid primary key default gen_random_uuid(),
  vendor_id   uuid not null references public.vendors (id) on delete cascade,
  body        text not null,
  created_at  timestamptz not null default now()
);

create or replace function public.my_vendor_id()
returns uuid language sql stable security definer set search_path = '' as $$
  select id from public.vendors where user_id = auth.uid() limit 1
$$;

-- ---------- projects --------------------------------------------------------
-- projects: what agents and introduced vendors may see
create table if not exists public.projects (
  id              uuid primary key default gen_random_uuid(),
  agent_id        uuid references public.profiles (id) on delete set null,
  agent_name      text not null,
  agent_email     text,
  agent_phone     text,
  brokerage       text,
  address         text not null,
  area            text,
  client_type     text not null default 'Seller' check (client_type in ('Seller', 'Buyer', 'Both')),
  target_date     date,
  categories      text[] not null default '{}',
  notes           text,
  added_services  jsonb not null default '{}',
  listed          boolean not null default false,
  listed_at       timestamptz,
  source          text,
  created_by      text,
  created_at      timestamptz not null default now()
);
-- project_private: agent and Ashleigh only (vendors never see these)
create table if not exists public.project_private (
  project_id       uuid primary key references public.projects (id) on delete cascade,
  client_name      text,
  budget           text check (budget in ('budget', 'mid', 'premium')),
  pm_interest      text,
  option_requests  jsonb not null default '{}'
);
-- project_admin: Ashleigh only (project management and close-out)
create table if not exists public.project_admin (
  project_id   uuid primary key references public.projects (id) on delete cascade,
  pm           boolean not null default false,
  pm_invoice   jsonb,
  completed    boolean not null default false,
  admin_notes  text
);
-- project_members: people a project is shared with
create table if not exists public.project_members (
  id            uuid primary key default gen_random_uuid(),
  project_id    uuid not null references public.projects (id) on delete cascade,
  user_id       uuid references auth.users (id) on delete set null,
  name          text not null,
  email         text not null,
  role          text not null default 'Team member',
  notify        boolean not null default false,
  from_default  boolean not null default false,
  added_by      uuid references auth.users (id) on delete set null,
  added_at      timestamptz not null default now(),
  unique (project_id, email)
);
-- default_shares: an agent's "Always share with" list
create table if not exists public.default_shares (
  id        uuid primary key default gen_random_uuid(),
  owner_id  uuid not null references public.profiles (id) on delete cascade,
  name      text not null,
  email     text not null,
  role      text not null default 'Assistant or coordinator',
  notify    boolean not null default false,
  added_at  timestamptz not null default now(),
  unique (owner_id, email)
);

create or replace function public.on_project(pid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.is_active() and (
    exists (select 1 from public.projects p where p.id = pid and p.agent_id = auth.uid())
    or exists (select 1 from public.project_members m
               where m.project_id = pid
                 and (m.user_id = auth.uid() or lower(m.email) = public.my_email())))
$$;

create or replace function public.owns_project(pid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.is_active() and exists (select 1 from public.projects p where p.id = pid and p.agent_id = auth.uid())
$$;

-- ---------- bids ------------------------------------------------------------
create table if not exists public.bids (
  id                  uuid primary key default gen_random_uuid(),
  project_id          uuid not null references public.projects (id) on delete cascade,
  category            text not null,
  vendor_id           uuid references public.vendors (id) on delete set null,
  vendor_name         text,           -- for a quote from someone not on the roster
  status              text not null default 'requested'
                      check (status in ('requested', 'submitted', 'changes', 'chosen', 'selected', 'passed', 'declined')),
  introduced_at       timestamptz,
  introduced_by       text,
  intro_note          text,
  avail_checked       boolean not null default false,
  suggest_rank        integer,
  requested_at        timestamptz not null default now(),
  amount              numeric(12, 2),
  days                integer,
  note                text,
  quote_path          text,           -- file in the "quotes" storage bucket
  quote_name          text,
  quote_is_image      boolean not null default false,
  submitted_at        timestamptz,
  rev                 integer not null default 0,
  prev_amount         numeric(12, 2),
  change_note         text,
  changes_at          timestamptz,
  changes_by          text,
  chosen_at           timestamptz,
  confirmed_at        timestamptz,
  start_date          date,
  confirm_note        text,
  decline_reason      text,
  decline_stage       text check (decline_stage in ('request', 'chosen')),
  decline_note        text,
  declined_at         timestamptz,
  step_agreement      boolean not null default false,
  step_paid           boolean not null default false,
  done                boolean not null default false,
  done_at             timestamptz,
  final_amount        numeric(12, 2),
  final_note          text,
  final_reported_by   text,
  final_reported_at   timestamptz,
  final_confirmed_at  timestamptz,
  final_dispute       jsonb,
  fee_type            text check (fee_type in ('first', 'repeat', 'waived')),
  created_at          timestamptz not null default now()
);

create or replace function public.vendor_on_project(pid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.bids b
                 where b.project_id = pid and b.vendor_id = public.my_vendor_id())
$$;


-- invoices: Orbyt's fee per booked job (Ashleigh manages; vendors can read their own)
create table if not exists public.invoices (
  bid_id      uuid primary key references public.bids (id) on delete cascade,
  status      text not null default 'ready' check (status in ('ready', 'invoiced', 'paid', 'waived')),
  number      text,
  fee         numeric(12, 2),
  invoiced_at timestamptz,
  paid_at     timestamptz,
  note        text
);

-- ---------- reviews, favorites, tasks ----------------------------------------
create table if not exists public.reviews (
  id          uuid primary key default gen_random_uuid(),
  bid_id      uuid unique references public.bids (id) on delete set null,
  vendor_id   uuid not null references public.vendors (id) on delete cascade,
  project_id  uuid references public.projects (id) on delete set null,
  agent_id    uuid references public.profiles (id) on delete set null,
  agent_name  text,
  rating      integer not null check (rating between 1 and 5),
  comment     text,
  approved    boolean not null default false,
  created_at  timestamptz not null default now()
);
create table if not exists public.favorites (
  user_id    uuid not null references public.profiles (id) on delete cascade,
  vendor_id  uuid not null references public.vendors (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, vendor_id)
);
create or replace function public.can_see_vendor(vid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.is_admin()
      or vid = public.my_vendor_id()
      or exists (select 1 from public.bids b where b.vendor_id = vid and public.on_project(b.project_id))
      or exists (select 1 from public.favorites f where f.user_id = auth.uid() and f.vendor_id = vid)
$$;

-- task_checks: which tasks someone checked off (or nudged)
create table if not exists public.task_checks (
  user_id    uuid not null references public.profiles (id) on delete cascade,
  task_id    text not null,
  checked_at timestamptz,
  nudged_at  timestamptz,
  primary key (user_id, task_id)
);

-- ---------- client links (no login) -----------------------------------------
create table if not exists public.client_links (
  id          uuid primary key default gen_random_uuid(),
  project_id  uuid not null references public.projects (id) on delete cascade,
  token       text not null unique default (replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')),
  created_by  uuid references auth.users (id) on delete set null,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz,
  revoked_at  timestamptz
);

-- ---------- Ashleigh's back office --------------------------------------------
create table if not exists public.my_tasks (
  id         uuid primary key default gen_random_uuid(),
  title      text not null,
  due        date,
  project_id uuid references public.projects (id) on delete set null,
  done       boolean not null default false,
  done_at    timestamptz,
  created_at timestamptz not null default now()
);
create table if not exists public.time_logs (
  id          uuid primary key default gen_random_uuid(),
  project_id  uuid references public.projects (id) on delete set null,
  kind        text not null default 'matching',
  hours       numeric(6, 2) not null check (hours > 0),
  note        text,
  logged_on   date not null default current_date,
  created_at  timestamptz not null default now()
);
create table if not exists public.spend (
  id          uuid primary key default gen_random_uuid(),
  spent_on    date not null default current_date,
  amount      numeric(12, 2) not null,
  category    text,
  note        text,
  created_at  timestamptz not null default now()
);
create table if not exists public.contacts (
  id          uuid primary key default gen_random_uuid(),
  side        text not null check (side in ('agent', 'vendor')),
  name        text,
  email       text,
  phone       text,
  company     text,
  source      text,
  imported_at timestamptz not null default now()
);
create table if not exists public.market_requests (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references auth.users (id) on delete set null,
  area        text not null,
  role        text,
  name        text,
  email       text,
  company     text,
  note        text,
  source      text,
  created_at  timestamptz not null default now()
);
create table if not exists public.settings (
  key        text primary key,
  value      jsonb,
  is_public  boolean not null default false
);
insert into public.settings (key, value, is_public)
values ('match_mode', '"hand"', true), ('pm_hire_rate', '0', false)
on conflict (key) do nothing;
insert into public.settings (key, value, is_public)
values ('main', '{"matching": "hand"}', true), ('config', '{}', false)
on conflict (key) do nothing;

-- fields added after the first version (safe to run again)
alter table public.bids           add column if not exists done_by      text;
alter table public.project_admin  add column if not exists completed_at timestamptz;
alter table public.vendor_private add column if not exists coi_url      text;
alter table public.contacts       add column if not exists area         text;
alter table public.spend          add column if not exists side         text;
alter table public.spend          add column if not exists channel      text;
alter table public.bids           add column if not exists available_from date;
alter table public.vendor_private add column if not exists pricing jsonb not null default '{}';
alter table public.projects       add column if not exists work_order jsonb;

-- ---------- indexes ---------------------------------------------------------
create index if not exists projects_agent_idx       on public.projects (agent_id);
create index if not exists members_project_idx      on public.project_members (project_id);
create index if not exists members_user_idx         on public.project_members (user_id);
create index if not exists members_email_idx        on public.project_members (lower(email));
create index if not exists bids_project_idx         on public.bids (project_id);
create index if not exists bids_vendor_idx          on public.bids (vendor_id);
create index if not exists reviews_vendor_idx       on public.reviews (vendor_id);
create index if not exists vendors_email_idx        on public.vendors (lower(email));
create index if not exists vendor_notes_vendor_idx  on public.vendor_notes (vendor_id);
create index if not exists client_links_project_idx on public.client_links (project_id);

-- =====================================================================
-- Sign-up: every new login gets a profile. Vendors also get a vendor
-- record, or are linked to the one already on the roster with their email.
-- People invited to a project skip the approval wait.
-- Nobody can make themselves an admin from the sign-up form.
-- =====================================================================
-- ---------- Terms of Use: agents and vendors agree with a checkbox, no signature ----------
create table if not exists public.terms_acceptances (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid references auth.users (id) on delete set null,
  email           text not null,
  role            text not null check (role in ('agent', 'vendor')),
  version         text not null,
  source          text not null default 'portal' check (source in ('signup', 'portal')),
  accepted_at     timestamptz not null default now(),
  ip              text,
  first_login_ip  text,
  user_agent      text
);
create index if not exists terms_acceptances_user_idx on public.terms_acceptances (user_id);
alter table public.terms_acceptances enable row level security;

drop policy if exists terms_acceptances_read on public.terms_acceptances;
-- people see their own record; Ashleigh sees everyone's. Records are only written by the functions below.
create policy terms_acceptances_read on public.terms_acceptances for select to authenticated
  using (public.is_admin() or user_id = auth.uid());
grant select on public.terms_acceptances to authenticated;
revoke all on public.terms_acceptances from anon;

-- the visitor's IP address, as passed along by Supabase's gateway
create or replace function public.request_ip()
returns text language sql stable set search_path = '' as $$
  select nullif(trim(split_part(coalesce(
    nullif(current_setting('request.headers', true), '')::json ->> 'x-forwarded-for',
    nullif(current_setting('request.headers', true), '')::json ->> 'x-real-ip', ''), ',', 1)), '')
$$;

-- agree in the portal (people who joined before the checkbox, or after the terms change)
create or replace function public.accept_terms(p_version text, p_user_agent text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare r text; em text; new_id uuid;
begin
  select role, lower(email) into r, em from public.profiles where id = auth.uid();
  if r is null or r not in ('agent', 'vendor') then raise exception 'Only agents and vendors accept these terms'; end if;
  if p_version is null or p_version not like r || '-terms-%' then raise exception 'Those terms are not for this account'; end if;
  insert into public.terms_acceptances (user_id, email, role, version, source, ip, user_agent)
  values (auth.uid(), em, r, p_version, 'portal', public.request_ip(), left(p_user_agent, 300))
  returning id into new_id;
  return new_id;
end $$;

-- people who agreed on the sign-up form: note the IP address the first time they sign in
create or replace function public.note_terms_login()
returns void language sql security definer set search_path = '' as $$
  update public.terms_acceptances set first_login_ip = public.request_ip()
  where user_id = auth.uid() and source = 'signup' and first_login_ip is null
$$;

revoke execute on function public.accept_terms(text, text) from public, anon;
revoke execute on function public.note_terms_login() from public, anon;
grant execute on function public.accept_terms(text, text) to authenticated;
grant execute on function public.note_terms_login() to authenticated;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  m        jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  r        text  := case when m ->> 'role' = 'vendor' then 'vendor' else 'agent' end;
  em       text  := lower(new.email);
  invited  boolean;
  v_id     uuid;
begin
  -- agents who are already on a project (shared with them, or imported/added by Orbyt under their email)
  -- and vendors Orbyt already approved skip the approval wait
  invited := (r = 'agent' and (
    exists (select 1 from public.project_members where lower(email) = em)
    or exists (select 1 from public.default_shares where lower(email) = em)
    or exists (select 1 from public.projects where agent_id is null and lower(agent_email) = em)))
    or (r = 'vendor' and exists (select 1 from public.vendors v join public.vendor_admin a on a.vendor_id = v.id
                                 where v.user_id is null and lower(v.email) = em and a.approved));

  insert into public.profiles (id, role, status, full_name, email, phone, brokerage, areas, approved_at)
  values (new.id, r, case when invited then 'active' else 'pending' end,
          nullif(trim(m ->> 'full_name'), ''), em, m ->> 'phone', m ->> 'brokerage',
          public.jsonb_text_array(m -> 'areas'), case when invited then now() end)
  on conflict (id) do nothing;

  update public.project_members set user_id = new.id where user_id is null and lower(email) = em;
  if r = 'agent' then
    update public.projects set agent_id = new.id where agent_id is null and lower(agent_email) = em;
  end if;

  if r = 'vendor' then
    select id into v_id from public.vendors where user_id is null and lower(email) = em limit 1;
    if v_id is null then
      insert into public.vendors (user_id, name, contact_name, email, phone, website, services, areas,
                                  years_in_business, team_size, lead_time, works_with_agents, portfolio_url, source)
      values (new.id, coalesce(nullif(trim(m ->> 'company'), ''), nullif(trim(m ->> 'full_name'), ''), em),
              m ->> 'full_name', em, m ->> 'phone', m ->> 'website',
              public.jsonb_text_array(m -> 'services'), public.jsonb_text_array(m -> 'areas'),
              m ->> 'years_in_business', m ->> 'team_size', m ->> 'lead_time',
              m ->> 'works_with_agents', m ->> 'portfolio_url', 'Portal sign-up')
      returning id into v_id;
      insert into public.vendor_admin (vendor_id) values (v_id) on conflict do nothing;
    else
      update public.vendors set user_id = new.id where id = v_id;
      insert into public.vendor_admin (vendor_id) values (v_id) on conflict do nothing;
    end if;
    insert into public.vendor_private (vendor_id, references_text, heard_about, signup_notes, promo_interest)
    values (v_id, m ->> 'references', m ->> 'heard_about', m ->> 'signup_notes', m ->> 'promo_interest')
    on conflict (vendor_id) do update set
      references_text = coalesce(excluded.references_text, public.vendor_private.references_text),
      heard_about     = coalesce(excluded.heard_about,     public.vendor_private.heard_about),
      signup_notes    = coalesce(excluded.signup_notes,    public.vendor_private.signup_notes),
      promo_interest  = coalesce(excluded.promo_interest,  public.vendor_private.promo_interest);
  end if;
  -- Terms of Use accepted with the checkbox on the sign-up form
  if (m ->> 'terms_version') like r || '-terms-%' then
    insert into public.terms_acceptances (user_id, email, role, version, source, user_agent)
    values (new.id, em, r, m ->> 'terms_version', 'signup', left(m ->> 'user_agent', 300));
  end if;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- New projects get their private and admin rows automatically.
create or replace function public.project_rows()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.project_private (project_id) values (new.id) on conflict do nothing;
  insert into public.project_admin (project_id) values (new.id) on conflict do nothing;
  return new;
end $$;
drop trigger if exists project_rows on public.projects;
create trigger project_rows after insert on public.projects
  for each row execute function public.project_rows();

-- =====================================================================
-- Guards: rules about WHICH fields each person may change.
-- (auth.uid() is empty when Ashleigh runs SQL in the dashboard, which is allowed.)
-- =====================================================================
create or replace function public.profiles_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or public.is_admin() then return new; end if;
  if new.role is distinct from old.role or new.status is distinct from old.status
     or new.email is distinct from old.email or new.approved_at is distinct from old.approved_at then
    raise exception 'Only Orbyt can change your role, status or login email.';
  end if;
  return new;
end $$;
drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard before update on public.profiles
  for each row execute function public.profiles_guard();

create or replace function public.projects_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or public.is_admin() then return new; end if;
  if tg_op = 'INSERT' then
    if new.agent_id is distinct from auth.uid() then
      raise exception 'You can only add projects under your own name.';
    end if;
    return new;
  end if;
  if new.agent_id is distinct from old.agent_id then
    raise exception 'Only Orbyt can move a project to another agent.';
  end if;
  return new;
end $$;
drop trigger if exists projects_guard on public.projects;
create trigger projects_guard before insert or update on public.projects
  for each row execute function public.projects_guard();

create or replace function public.bids_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  is_vendor boolean;
  is_agent  boolean;
begin
  -- changes made by the database itself (like reopening quotes) are allowed
  -- remove_project_service() closes open requests for agents too
  if auth.uid() is null or pg_trigger_depth() > 1 or public.is_admin()
     or current_setting('orbyt.service_removal', true) = 'on' then return new; end if;
  is_vendor := coalesce(old.vendor_id = public.my_vendor_id(), false);
  is_agent  := coalesce(public.on_project(old.project_id), false);

  if new.project_id is distinct from old.project_id or new.vendor_id is distinct from old.vendor_id
     or new.vendor_name is distinct from old.vendor_name or new.category is distinct from old.category
     or new.introduced_at is distinct from old.introduced_at or new.introduced_by is distinct from old.introduced_by
     or new.intro_note is distinct from old.intro_note or new.avail_checked is distinct from old.avail_checked
     or new.suggest_rank is distinct from old.suggest_rank or new.requested_at is distinct from old.requested_at
     or new.fee_type is distinct from old.fee_type then
    raise exception 'Only Orbyt can change that part of a bid.';
  end if;

  if is_vendor and not is_agent then
    if new.step_agreement is distinct from old.step_agreement or new.step_paid is distinct from old.step_paid
       or new.chosen_at is distinct from old.chosen_at or new.change_note is distinct from old.change_note
       or new.changes_at is distinct from old.changes_at or new.changes_by is distinct from old.changes_by
       -- a vendor can clear the agent's confirmation or dispute (by reporting a new final amount), never set them
       or (new.final_confirmed_at is distinct from old.final_confirmed_at and new.final_confirmed_at is not null)
       or (new.final_dispute is distinct from old.final_dispute and new.final_dispute is not null) then
      raise exception 'That change has to come from the agent.';
    end if;
    if new.status is distinct from old.status and not (
         (old.status in ('requested', 'changes') and new.status in ('submitted', 'declined'))
      or (old.status = 'chosen' and new.status in ('selected', 'declined'))) then
      raise exception 'A vendor can''t move a bid from % to %.', old.status, new.status;
    end if;
    return new;
  end if;

  if is_agent and not is_vendor then
    if new.amount is distinct from old.amount or new.days is distinct from old.days or new.note is distinct from old.note
       or new.quote_path is distinct from old.quote_path or new.quote_name is distinct from old.quote_name
       or new.quote_is_image is distinct from old.quote_is_image or new.submitted_at is distinct from old.submitted_at
       or new.rev is distinct from old.rev or new.prev_amount is distinct from old.prev_amount
       or new.final_amount is distinct from old.final_amount or new.final_note is distinct from old.final_note
       or new.final_reported_by is distinct from old.final_reported_by or new.final_reported_at is distinct from old.final_reported_at
       or new.decline_reason is distinct from old.decline_reason or new.decline_stage is distinct from old.decline_stage
       or new.declined_at is distinct from old.declined_at or new.confirm_note is distinct from old.confirm_note
       or new.available_from is distinct from old.available_from then
      raise exception 'That change has to come from the vendor.';
    end if;
    if new.status is distinct from old.status and not (
         (old.status = 'submitted' and new.status in ('chosen', 'passed', 'changes'))
      or (old.status in ('chosen', 'selected', 'passed') and new.status = 'submitted')) then
      raise exception 'An agent can''t move a bid from % to %.', old.status, new.status;
    end if;
    return new;
  end if;

  if is_agent and is_vendor then return new; end if;
  raise exception 'You don''t have access to this bid.';
end $$;
drop trigger if exists bids_guard on public.bids;
create trigger bids_guard before update on public.bids
  for each row execute function public.bids_guard();

-- When a booked vendor backs out, the other quotes for that service open up again.
create or replace function public.bids_reopen()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'declined' and old.status in ('chosen', 'selected') then
    update public.bids set status = 'submitted'
     where project_id = new.project_id and category = new.category and status = 'passed' and id <> new.id;
  end if;
  return new;
end $$;
drop trigger if exists bids_reopen on public.bids;
create trigger bids_reopen after update on public.bids
  for each row execute function public.bids_reopen();

-- =====================================================================
-- Actions that need more than a simple save
-- =====================================================================
-- Approve or decline a sign-up (Ashleigh only).
create or replace function public.admin_set_user_status(p_user uuid, p_status text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Only Orbyt can approve accounts.'; end if;
  if p_status not in ('pending', 'active', 'declined') then raise exception 'Unknown status %', p_status; end if;
  update public.profiles
     set status = p_status, approved_at = case when p_status = 'active' then now() else approved_at end
   where id = p_user;
  if p_status = 'active' then
    update public.vendor_admin set approved = true, approved_at = now()
     where vendor_id in (select id from public.vendors where user_id = p_user);
  end if;
end $$;

-- Read-only quote page for a seller or buyer, opened from a private link.
create or replace function public.client_quotes(p_token text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'address', p.address, 'agent', p.agent_name, 'agent_email', p.agent_email, 'agent_phone', p.agent_phone,
    'target_date', p.target_date, 'client_type', p.client_type,
    'services', coalesce((
      select jsonb_agg(jsonb_build_object('service', c, 'quotes', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'bid_id', b.id, 'vendor', coalesce(v.name, b.vendor_name), 'amount', b.amount, 'days', b.days, 'available_from', b.available_from,
                 'note', b.note, 'booked', b.status in ('chosen', 'selected'), 'quote_name', b.quote_name,
                 'rating', (select round(avg(r.rating)::numeric, 1) from public.reviews r where r.vendor_id = b.vendor_id and r.approved),
                 'review_count', (select count(*) from public.reviews r where r.vendor_id = b.vendor_id and r.approved))
               order by b.submitted_at), '[]'::jsonb)
          from public.bids b left join public.vendors v on v.id = b.vendor_id
         where b.project_id = p.id and b.category = c and b.amount is not null
           and b.status in ('submitted', 'changes', 'chosen', 'selected'))) order by c)
      from unnest(p.categories) as c), '[]'::jsonb))
    from public.client_links l join public.projects p on p.id = l.project_id
   where l.token = p_token and l.revoked_at is null and (l.expires_at is null or l.expires_at > now())
$$;

-- =====================================================================
-- Row-level security: who can see and change each table
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array['profiles','vendors','vendor_admin','vendor_private','vendor_notes','projects',
    'project_private','project_admin','project_members','default_shares','bids','invoices','reviews',
    'favorites','task_checks','client_links','my_tasks','time_logs','spend','contacts','market_requests','settings']
  loop
    execute format('alter table public.%I enable row level security', t);
    -- start clean so this script can be run again
    execute (select coalesce(string_agg(format('drop policy if exists %I on public.%I;', policyname, t), ' '), 'select 1')
               from pg_policies where schemaname = 'public' and tablename = t);
  end loop;
end $$;

-- profiles
create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_admin());
create policy profiles_edit on public.profiles for update to authenticated
  using (id = auth.uid() or public.is_admin()) with check (id = auth.uid() or public.is_admin());

-- vendors and their side tables
create policy vendors_read on public.vendors for select to authenticated
  using (user_id = auth.uid() or public.can_see_vendor(id));
create policy vendors_add on public.vendors for insert to authenticated
  with check (public.is_admin());
create policy vendors_edit on public.vendors for update to authenticated
  using (user_id = auth.uid() or public.is_admin()) with check (user_id = auth.uid() or public.is_admin());
create policy vendors_remove on public.vendors for delete to authenticated
  using (public.is_admin());

create policy vendor_admin_read on public.vendor_admin for select to authenticated
  using (public.can_see_vendor(vendor_id));
create policy vendor_admin_write on public.vendor_admin for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy vendor_private_read on public.vendor_private for select to authenticated
  using (vendor_id = public.my_vendor_id() or public.is_admin());
create policy vendor_private_edit on public.vendor_private for update to authenticated
  using (vendor_id = public.my_vendor_id() or public.is_admin())
  with check (vendor_id = public.my_vendor_id() or public.is_admin());
create policy vendor_private_add on public.vendor_private for insert to authenticated
  with check (public.is_admin());

create policy vendor_notes_admin on public.vendor_notes for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- projects
create policy projects_read on public.projects for select to authenticated
  using (public.is_admin() or agent_id = auth.uid() or public.on_project(id) or public.vendor_on_project(id));
create policy projects_add on public.projects for insert to authenticated
  with check (public.is_admin() or (agent_id = auth.uid() and public.is_active()
              and exists (select 1 from public.profiles where id = auth.uid() and role = 'agent')));
create policy projects_edit on public.projects for update to authenticated
  using (public.is_admin() or public.on_project(id)) with check (public.is_admin() or public.on_project(id));
create policy projects_remove on public.projects for delete to authenticated
  using (public.is_admin());

create policy project_private_rw on public.project_private for all to authenticated
  using (public.is_admin() or public.on_project(project_id))
  with check (public.is_admin() or public.on_project(project_id));

create policy project_admin_rw on public.project_admin for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy members_read on public.project_members for select to authenticated
  using (public.is_admin() or public.on_project(project_id) or public.vendor_on_project(project_id));
create policy members_add on public.project_members for insert to authenticated
  with check (public.is_admin() or public.owns_project(project_id));
create policy members_edit on public.project_members for update to authenticated
  using (public.is_admin() or public.owns_project(project_id))
  with check (public.is_admin() or public.owns_project(project_id));
create policy members_remove on public.project_members for delete to authenticated
  using (public.is_admin() or public.owns_project(project_id));

create policy default_shares_rw on public.default_shares for all to authenticated
  using (owner_id = auth.uid() or public.is_admin())
  with check (owner_id = auth.uid() or public.is_admin());

-- bids
create policy bids_read on public.bids for select to authenticated
  using (public.is_admin() or vendor_id = public.my_vendor_id() or public.on_project(project_id));
create policy bids_add on public.bids for insert to authenticated
  with check (public.is_admin());
create policy bids_edit on public.bids for update to authenticated
  using (public.is_admin() or vendor_id = public.my_vendor_id() or public.on_project(project_id))
  with check (public.is_admin() or vendor_id = public.my_vendor_id() or public.on_project(project_id));
create policy bids_remove on public.bids for delete to authenticated
  using (public.is_admin());

-- invoices
create policy invoices_read on public.invoices for select to authenticated
  using (public.is_admin() or exists (select 1 from public.bids b
         where b.id = bid_id and b.vendor_id = public.my_vendor_id()));
create policy invoices_write on public.invoices for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- reviews
create policy reviews_read on public.reviews for select to authenticated
  using (public.is_admin() or agent_id = auth.uid() or (approved and public.can_see_vendor(vendor_id)));
create policy reviews_add on public.reviews for insert to authenticated
  with check (public.is_admin() or (
    agent_id = auth.uid() and approved = false and public.on_project(project_id)
    and exists (select 1 from public.bids b where b.id = bid_id and b.project_id = reviews.project_id
                and b.vendor_id = reviews.vendor_id and b.status = 'selected')));
create policy reviews_admin on public.reviews for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy reviews_remove on public.reviews for delete to authenticated
  using (public.is_admin());

-- favorites and task checks: each person's own
create policy favorites_own on public.favorites for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy task_checks_own on public.task_checks for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- client links
create policy client_links_rw on public.client_links for all to authenticated
  using (public.is_admin() or public.on_project(project_id))
  with check (public.is_admin() or public.on_project(project_id));

-- back office: Ashleigh only
create policy my_tasks_admin  on public.my_tasks  for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy time_logs_admin on public.time_logs for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy spend_admin     on public.spend     for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy contacts_admin  on public.contacts  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- new-area requests: anyone signed in can ask; only Ashleigh sees them all
create policy market_add on public.market_requests for insert to authenticated
  with check (user_id = auth.uid() or public.is_admin());
create policy market_read on public.market_requests for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
create policy market_admin on public.market_requests for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy market_remove on public.market_requests for delete to authenticated
  using (public.is_admin());

-- settings: some are shown in the portal (like how matching works)
create policy settings_read on public.settings for select to authenticated
  using (is_public or public.is_admin());
create policy settings_write on public.settings for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- =====================================================================
-- Permissions for the Data API ("Automatically expose new tables" is off)
-- Logged-out visitors get no table access at all.
-- =====================================================================
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on
  public.profiles, public.vendors, public.vendor_admin, public.vendor_private, public.vendor_notes,
  public.projects, public.project_private, public.project_admin, public.project_members, public.default_shares,
  public.bids, public.invoices, public.reviews, public.favorites, public.task_checks, public.client_links,
  public.my_tasks, public.time_logs, public.spend, public.contacts, public.market_requests, public.settings
  to authenticated;
revoke all on all tables in schema public from anon;

revoke execute on function public.admin_set_user_status(uuid, text) from public, anon;
grant execute on function public.admin_set_user_status(uuid, text) to authenticated;
revoke execute on function public.client_quotes(text) from public;
grant execute on function public.client_quotes(text) to anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- ---------- signed Vendor Network Agreements ----------
create table if not exists public.vendor_agreements (
  id             uuid primary key default gen_random_uuid(),
  vendor_id      uuid not null references public.vendors (id) on delete cascade,
  user_id        uuid references auth.users (id) on delete set null,
  version        text not null,
  legal_name     text not null,
  signer_name    text not null,
  signer_title   text,
  signer_email   text,
  details        jsonb not null default '{}',
  document_html  text not null,
  user_agent     text,
  signed_at      timestamptz not null default now()
);
create index if not exists vendor_agreements_vendor_idx on public.vendor_agreements (vendor_id);
alter table public.vendor_agreements enable row level security;

-- the signer and the time always come from the server, never from the browser
create or replace function public.vendor_agreements_stamp()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.user_id := auth.uid();
  new.signed_at := now();
  return new;
end $$;
drop trigger if exists vendor_agreements_stamp on public.vendor_agreements;
create trigger vendor_agreements_stamp before insert on public.vendor_agreements
  for each row execute function public.vendor_agreements_stamp();

drop policy if exists vendor_agreements_read on public.vendor_agreements;
drop policy if exists vendor_agreements_sign on public.vendor_agreements;
drop policy if exists vendor_agreements_admin on public.vendor_agreements;
-- a vendor sees their own; Ashleigh sees all
create policy vendor_agreements_read on public.vendor_agreements for select to authenticated
  using (public.is_admin() or vendor_id = public.my_vendor_id());
-- only an approved vendor can sign, and only for their own business
create policy vendor_agreements_sign on public.vendor_agreements for insert to authenticated
  with check (vendor_id = public.my_vendor_id() and public.is_active());
-- signed agreements can't be edited; only Ashleigh can remove one
create policy vendor_agreements_admin on public.vendor_agreements for delete to authenticated
  using (public.is_admin());

grant select, insert, delete on public.vendor_agreements to authenticated;
revoke all on public.vendor_agreements from anon;
revoke execute on function public.vendor_agreements_stamp() from public, anon, authenticated;

-- =====================================================================
-- File storage (private buckets)
--   quotes/<bid id>/<file>          vendor uploads, agent on the project reads
--   vendor-files/<vendor id>/<file> insurance certificates: vendor and Ashleigh
--   vendor-photos/<vendor id>/<file> portfolio photos: anyone signed in can view
-- =====================================================================
insert into storage.buckets (id, name, public) values
  ('quotes', 'quotes', false), ('vendor-files', 'vendor-files', false), ('vendor-photos', 'vendor-photos', false)
on conflict (id) do nothing;

drop policy if exists orbyt_quotes_read   on storage.objects;
drop policy if exists orbyt_quotes_write  on storage.objects;
drop policy if exists orbyt_quotes_change on storage.objects;
drop policy if exists orbyt_quotes_remove on storage.objects;
drop policy if exists orbyt_vfiles_rw     on storage.objects;
drop policy if exists orbyt_photos_read   on storage.objects;
drop policy if exists orbyt_photos_write  on storage.objects;
drop policy if exists orbyt_photos_remove on storage.objects;

create policy orbyt_quotes_read on storage.objects for select to authenticated
  using (bucket_id = 'quotes' and exists (
    select 1 from public.bids b where b.id::text = (storage.foldername(name))[1]
      and (b.vendor_id = public.my_vendor_id() or public.on_project(b.project_id) or public.is_admin())));
create policy orbyt_quotes_write on storage.objects for insert to authenticated
  with check (bucket_id = 'quotes' and exists (
    select 1 from public.bids b where b.id::text = (storage.foldername(name))[1]
      and (b.vendor_id = public.my_vendor_id() or public.is_admin())));
create policy orbyt_quotes_change on storage.objects for update to authenticated
  using (bucket_id = 'quotes' and exists (
    select 1 from public.bids b where b.id::text = (storage.foldername(name))[1]
      and (b.vendor_id = public.my_vendor_id() or public.is_admin())));
create policy orbyt_quotes_remove on storage.objects for delete to authenticated
  using (bucket_id = 'quotes' and exists (
    select 1 from public.bids b where b.id::text = (storage.foldername(name))[1]
      and (b.vendor_id = public.my_vendor_id() or public.is_admin())));

create policy orbyt_vfiles_rw on storage.objects for all to authenticated
  using (bucket_id = 'vendor-files' and ((storage.foldername(name))[1] = public.my_vendor_id()::text or public.is_admin()))
  with check (bucket_id = 'vendor-files' and ((storage.foldername(name))[1] = public.my_vendor_id()::text or public.is_admin()));

create policy orbyt_photos_read on storage.objects for select to authenticated
  using (bucket_id = 'vendor-photos');
create policy orbyt_photos_write on storage.objects for insert to authenticated
  with check (bucket_id = 'vendor-photos' and ((storage.foldername(name))[1] = public.my_vendor_id()::text or public.is_admin()));
create policy orbyt_photos_remove on storage.objects for delete to authenticated
  using (bucket_id = 'vendor-photos' and ((storage.foldername(name))[1] = public.my_vendor_id()::text or public.is_admin()));

-- =====================================================================
-- Notification emails (Resend), from update 4
-- =====================================================================
-- Before this works, store the Resend key once (a separate SQL snippet, with your real key):
--   select vault.create_secret('re_your_key_here', 'resend_api_key', 'Resend key for Orbyt notification emails');

create extension if not exists pg_net;

-- Settings for every email. Change portal_url here when the portal moves to portal.orbytconnect.com.
insert into public.settings (key, value, is_public)
values ('email', jsonb_build_object(
  'enabled', true,
  'portal_url', 'https://portal.orbytconnect.com',
  'from', 'Orbyt <ashleigh@orbytconnect.com>',
  'admin', 'ashleigh@orbytconnect.com',
  'logo', 'https://portal.orbytconnect.com/orbyt-logo-email.png'), false)
on conflict (key) do nothing;

-- A record of every notification, so you can see what went out (Table Editor, email_log).
create table if not exists public.email_log (
  id          bigint generated always as identity primary key,
  sent_at     timestamptz not null default now(),
  kind        text,
  to_email    text,
  subject     text,
  status      text,
  request_id  bigint
);
alter table public.email_log enable row level security;
drop policy if exists email_log_admin on public.email_log;
create policy email_log_admin on public.email_log for select to authenticated using (public.is_admin());
grant select on public.email_log to authenticated;
revoke all on public.email_log from anon;

-- ---------- building blocks ----------
create or replace function public.h(t text) returns text language sql immutable set search_path = '' as $$
  select replace(replace(replace(replace(coalesce(t, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;')
$$;
create or replace function public.ep(t text) returns text language sql immutable set search_path = '' as $$
  select '<p style="font-size:15px;line-height:1.6;margin:0 0 12px">' || coalesce(t, '') || '</p>'
$$;
create or replace function public.first_name(t text) returns text language sql immutable set search_path = '' as $$
  select coalesce(nullif(split_part(trim(coalesce(t, '')), ' ', 1), ''), 'there')
$$;
create or replace function public.money_text(n numeric) returns text language sql immutable set search_path = '' as $$
  select case when n is null then '' else '$' || trim(to_char(n, 'FM999,999,990')) end
$$;
create or replace function public.date_text(d date) returns text language sql immutable set search_path = '' as $$
  select case when d is null then '' else trim(to_char(d, 'FMMonth FMDD')) end
$$;

-- Sends one branded email to each address in p_to.
create or replace function public.orbyt_email(p_to text[], p_subject text, p_heading text, p_body text, p_button text, p_kind text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  cfg  jsonb;
  k    text;
  addr text;
  html text;
  rid  bigint;
begin
  select value into cfg from public.settings where key = 'email';
  if cfg is null or coalesce((cfg ->> 'enabled')::boolean, false) = false then return; end if;
  html := '<div style="background:#F6F4EA;padding:32px 16px;font-family:Arial,Helvetica,sans-serif;color:#18314F">'
       || '<div style="max-width:520px;margin:0 auto;background:#ffffff;border-radius:12px;padding:32px">'
       || '<img src="' || (cfg ->> 'logo') || '" width="180" alt="Orbyt" style="display:block;width:180px;max-width:100%;height:auto;border:0;margin:0 0 24px">'
       || '<h1 style="font-size:22px;font-weight:500;margin:0 0 12px;color:#18314F">' || public.h(p_heading) || '</h1>'
       || p_body
       || '<p style="margin:20px 0 24px"><a href="' || (cfg ->> 'portal_url') || '" style="background:#18314F;color:#ffffff;text-decoration:none;padding:12px 24px;border-radius:999px;font-size:15px;display:inline-block">' || public.h(p_button) || '</a></p>'
       || '<p style="font-size:14px;line-height:1.6;color:#2C4260;margin:0">Questions? Just reply. Ashleigh at Orbyt</p>'
       || '</div></div>';
  select decrypted_secret into k from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  for addr in select distinct lower(trim(x)) from unnest(p_to) as x where x is not null and trim(x) like '%_@_%.%' loop
    begin
      if k is null then
        insert into public.email_log (kind, to_email, subject, status) values (p_kind, addr, p_subject, 'not sent: Resend key missing');
        continue;
      end if;
      select net.http_post(
        url     := 'https://api.resend.com/emails',
        headers := jsonb_build_object('Authorization', 'Bearer ' || k, 'Content-Type', 'application/json'),
        body    := jsonb_build_object('from', cfg ->> 'from', 'to', jsonb_build_array(addr), 'reply_to', cfg ->> 'admin',
                                      'subject', p_subject, 'html', html)
      ) into rid;
      insert into public.email_log (kind, to_email, subject, status, request_id) values (p_kind, addr, p_subject, 'queued', rid);
    exception when others then
      raise warning 'Orbyt email not sent to %: %', addr, sqlerrm;
    end;
  end loop;
exception when others then
  raise warning 'Orbyt email not sent: %', sqlerrm;
end $$;

-- Who hears about a project: the agent, plus anyone shared on it with "Gets emails" on.
create or replace function public.project_recipients(pid uuid) returns text[] language sql stable security definer set search_path = '' as $$
  select array_remove(array[p.agent_email]
         || coalesce((select array_agg(m.email) from public.project_members m where m.project_id = pid and m.notify), '{}'), null)
    from public.projects p where p.id = pid
$$;
create or replace function public.vendor_email(vid uuid) returns text language sql stable security definer set search_path = '' as $$
  select coalesce((select u.email from auth.users u where u.id = v.user_id), v.email) from public.vendors v where v.id = vid
$$;
create or replace function public.admin_email() returns text language sql stable security definer set search_path = '' as $$
  select value ->> 'admin' from public.settings where key = 'email'
$$;

-- ---------- bids: requests, bids, picks, confirmations, finished jobs ----------
create or replace function public.bids_notify() returns trigger language plpgsql security definer set search_path = '' as $$
declare
  p      public.projects%rowtype;
  v      public.vendors%rowtype;
  vname  text;
  cat    text := lower(new.category);
  place  text;
  team   text[];
begin
  select * into p from public.projects where id = new.project_id;
  if p.id is null then return new; end if;
  select * into v from public.vendors where id = new.vendor_id;
  vname := coalesce(v.name, new.vendor_name, 'A vendor');
  place := '<b>' || public.h(p.address) || '</b>';
  team  := public.project_recipients(p.id);

  -- a new introduction: the vendor gets a bid request
  if tg_op = 'INSERT' then
    if new.status = 'requested' and v.id is not null then
      perform public.orbyt_email(array[public.vendor_email(v.id)],
        'New bid request: ' || new.category || ' at ' || p.address, 'New bid request',
        public.ep('Hi ' || public.h(public.first_name(coalesce(v.contact_name, v.name))) || ', ' || public.h(p.agent_name) || ' needs ' || public.h(cat)
                  || ' at ' || place || case when p.target_date is not null then ', with a target date of ' || public.date_text(p.target_date) else '' end || '.')
        || case when coalesce(new.intro_note, '') <> '' then public.ep('A note from Ashleigh: &ldquo;' || public.h(new.intro_note) || '&rdquo;') else '' end
        || public.ep('Sign in to see the details and send your bid. A PDF or a clear photo of your quote works.'),
        'See the request', 'bid_request');
    elsif new.status = 'submitted' then
      perform public.orbyt_email(team, 'New ' || cat || ' bid for ' || p.address, 'A new bid is in',
        public.ep(public.h(vname) || ' sent a ' || public.h(cat) || ' bid for ' || place || ': ' || public.money_text(new.amount) || '.')
        || public.ep('Sign in to compare it with the others and add your pick to the team.'),
        'Compare bids', 'bid_in');
    end if;
    return new;
  end if;

  if new.status is distinct from old.status then
    if new.status = 'submitted' and old.status in ('requested', 'changes') then
      perform public.orbyt_email(team,
        case when old.status = 'changes' then 'Updated ' else 'New ' end || cat || ' bid for ' || p.address,
        case when old.status = 'changes' then 'An updated bid is in' else 'A new bid is in' end,
        public.ep(public.h(vname) || case when old.status = 'changes' then ' updated their ' else ' sent a ' end || public.h(cat) || ' bid for ' || place
                  || ': ' || public.money_text(new.amount) || case when new.available_from is not null then ', and they can start ' || public.date_text(new.available_from) else '' end || '.')
        || public.ep('Sign in to see their quote, compare it with the others and add your pick to the team.'),
        'Compare bids', 'bid_in');
    elsif new.status = 'changes' and v.id is not null then
      perform public.orbyt_email(array[public.vendor_email(v.id)], 'Changes requested on your ' || cat || ' bid', 'They asked for a change',
        public.ep('Hi ' || public.h(public.first_name(coalesce(v.contact_name, v.name))) || ', ' || public.h(coalesce(new.changes_by, p.agent_name)) || ' asked for a change to your ' || public.h(cat) || ' bid for ' || place || '.')
        || case when coalesce(new.change_note, '') <> '' then public.ep('&ldquo;' || public.h(new.change_note) || '&rdquo;') else '' end
        || public.ep('Sign in to send an updated bid.'),
        'Update my bid', 'changes');
    elsif new.status = 'chosen' and v.id is not null then
      perform public.orbyt_email(array[public.vendor_email(v.id)], 'You''re on the team for ' || p.address, 'You''re on the team',
        public.ep('Good news, ' || public.h(public.first_name(coalesce(v.contact_name, v.name))) || '. ' || public.h(p.agent_name) || ' picked you for the ' || public.h(cat) || ' at ' || place || '.')
        || public.ep('Sign in to confirm the job and propose a start date. Then reach out to ' || public.h(public.first_name(p.agent_name)) || ' to schedule, and share your agreement and payment details with the client directly.'),
        'Confirm the job', 'chosen');
    elsif new.status = 'passed' and old.status in ('submitted', 'changes') and v.id is not null then
      perform public.orbyt_email(array[public.vendor_email(v.id)], 'An update on your ' || cat || ' bid for ' || p.address, 'Thanks for bidding',
        public.ep('Hi ' || public.h(public.first_name(coalesce(v.contact_name, v.name))) || ', the client went with another vendor for the ' || public.h(cat) || ' at ' || place || ' this time.')
        || public.ep('Thanks for sending such a quick bid. I''ll keep introducing you to agents who need what you do.'),
        'See my requests', 'passed');
    elsif new.status = 'selected' then
      perform public.orbyt_email(team, vname || ' confirmed the ' || cat || ' at ' || p.address, 'Booked and confirmed',
        public.ep(public.h(vname) || ' confirmed the ' || public.h(cat) || ' at ' || place
                  || case when new.start_date is not null then ' and proposed starting ' || public.date_text(new.start_date) else '' end || '.')
        || case when coalesce(new.confirm_note, '') <> '' then public.ep('Their note: &ldquo;' || public.h(new.confirm_note) || '&rdquo;') else '' end
        || public.ep('They''ll reach out to schedule and send their agreement and payment details to your client.'),
        'See the project', 'confirmed');
    elsif new.status = 'declined' and old.status in ('chosen', 'selected') then
      perform public.orbyt_email(team || array[public.admin_email()], vname || ' can''t take the ' || cat || ' at ' || p.address, 'A vendor had to step back',
        public.ep(public.h(vname) || ' let us know they can''t do the ' || public.h(cat) || ' at ' || place
                  || case when coalesce(new.decline_reason, '') <> '' then ' (' || public.h(lower(new.decline_reason)) || ')' else '' end || '.')
        || public.ep('The other bids are open again, so you can pick someone else, or ask Ashleigh for another option.'),
        'See the project', 'stepped_back');
    end if;
  end if;

  -- the vendor reported the job done and the final amount
  if new.final_reported_at is distinct from old.final_reported_at and new.final_reported_by = 'vendor' and new.final_reported_at is not null then
    perform public.orbyt_email(team, 'Confirm the final amount for ' || p.address, vname || ' finished the job',
      public.ep(public.h(vname) || ' marked the ' || public.h(cat) || ' at ' || place || ' complete, with a final invoice of ' || public.money_text(new.final_amount) || '.')
      || public.ep('Sign in to confirm the amount, and leave a quick review. It helps other agents pick great vendors.'),
      'Confirm and review', 'job_done');
  end if;
  return new;
exception when others then
  raise warning 'Orbyt bid email skipped: %', sqlerrm;
  return new;
end $$;
drop trigger if exists bids_notify on public.bids;
create trigger bids_notify after insert or update on public.bids
  for each row execute function public.bids_notify();

-- ---------- sign-ups and approvals ----------
create or replace function public.profiles_notify() returns trigger language plpgsql security definer set search_path = '' as $$
declare
  meta jsonb;
  who  text;
begin
  if tg_op = 'INSERT' then
    if new.status = 'pending' then
      select raw_user_meta_data into meta from auth.users where id = new.id;
      who := coalesce(nullif(trim(meta ->> 'company'), ''), new.full_name, new.email);
      perform public.orbyt_email(array[public.admin_email()],
        'New ' || new.role || ' sign-up: ' || who, 'New ' || new.role || ' sign-up',
        public.ep('<b>' || public.h(who) || '</b>' || case when new.role = 'vendor' and coalesce(meta ->> 'full_name', '') <> '' then ' (' || public.h(meta ->> 'full_name') || ')' else '' end
                  || ' just joined as ' || case when new.role = 'vendor' then 'a vendor partner' else 'an agent' end || '. ' || public.h(new.email)
                  || case when coalesce(new.phone, '') <> '' then ', ' || public.h(new.phone) else '' end || '.')
        || case when coalesce(meta ->> 'services', '') <> '' then public.ep('Services: ' || public.h(array_to_string(public.jsonb_text_array(meta -> 'services'), ', '))) else '' end
        || case when cardinality(new.areas) > 0 then public.ep('Areas: ' || public.h(array_to_string(new.areas, ', '))) else '' end
        || case when coalesce(new.brokerage, '') <> '' then public.ep('Brokerage: ' || public.h(new.brokerage)) else '' end,
        'Review in Orbyt', 'admin_signup');
    end if;
    return new;
  end if;
  if new.status = 'active' and old.status = 'pending' then
    if new.role = 'vendor' then
      perform public.orbyt_email(array[new.email], 'You''re approved for the Orbyt network', 'You''re in, ' || public.first_name(new.full_name),
        public.ep('Thanks for your patience while I checked everything. You''re approved as an Orbyt vendor partner.')
        || public.ep('When you sign in, you''ll see exactly what Orbyt costs (you only pay when an introduction turns into a paid job) and the insurance paperwork your services need.'),
        'Sign in to Orbyt', 'approved');
    elsif new.role = 'agent' then
      perform public.orbyt_email(array[new.email], 'You''re approved for Orbyt', 'You''re in, ' || public.first_name(new.full_name),
        public.ep('Your Orbyt account is ready. Add your first project with the address and what the home needs, and I''ll start lining up vendors matched to it.')
        || public.ep('You''ll get an email here as soon as bids come in.'),
        'Start a project', 'approved');
    end if;
  end if;
  return new;
exception when others then
  raise warning 'Orbyt sign-up email skipped: %', sqlerrm;
  return new;
end $$;
drop trigger if exists profiles_notify on public.profiles;
create trigger profiles_notify after insert or update of status on public.profiles
  for each row execute function public.profiles_notify();

-- ---------- a project is shared with someone ----------
create or replace function public.members_notify() returns trigger language plpgsql security definer set search_path = '' as $$
declare
  p          public.projects%rowtype;
  has_login  boolean;
begin
  select * into p from public.projects where id = new.project_id;
  if p.id is null or lower(new.email) = lower(coalesce(p.agent_email, '')) then return new; end if;
  has_login := exists (select 1 from auth.users where lower(email) = lower(new.email));
  perform public.orbyt_email(array[new.email], p.agent_name || ' shared ' || p.address || ' with you', 'You''ve been added to a project',
    public.ep('Hi ' || public.h(public.first_name(new.name)) || ', ' || public.h(p.agent_name) || ' added you to <b>' || public.h(p.address) || '</b> on Orbyt as ' || public.h(lower(new.role)) || '.')
    || public.ep('You can see the vendors, compare bids and follow along as the team comes together.')
    || case when has_login then public.ep('Sign in with ' || public.h(new.email) || ' to see it.')
            else public.ep('Create your account with this email, ' || public.h(new.email) || ', and you''ll land right on the project. No approval wait.') end,
    case when has_login then 'See the project' else 'Create my account' end, 'shared');
  return new;
exception when others then
  raise warning 'Orbyt sharing email skipped: %', sqlerrm;
  return new;
end $$;
drop trigger if exists members_notify on public.project_members;
create trigger members_notify after insert on public.project_members
  for each row execute function public.members_notify();

-- ---------- for Ashleigh: new projects from agents, signed agreements ----------
create or replace function public.projects_notify() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if public.is_admin() then return new; end if;
  perform public.orbyt_email(array[public.admin_email()], 'New project from ' || new.agent_name || ': ' || new.address, 'A new project needs matching',
    public.ep(public.h(new.agent_name) || ' added <b>' || public.h(new.address) || '</b>' || case when coalesce(new.area, '') <> '' then ' in ' || public.h(new.area) else '' end
              || case when new.target_date is not null then ', target date ' || public.date_text(new.target_date) else '' end || '.')
    || public.ep('Needs: ' || public.h(array_to_string(new.categories, ', ')))
    || case when coalesce(new.notes, '') <> '' then public.ep('Notes: ' || public.h(new.notes)) else '' end,
    'Start matching', 'admin_project');
  return new;
exception when others then
  raise warning 'Orbyt project email skipped: %', sqlerrm;
  return new;
end $$;
drop trigger if exists projects_notify on public.projects;
create trigger projects_notify after insert on public.projects
  for each row execute function public.projects_notify();

create or replace function public.agreements_notify() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform public.orbyt_email(array[public.admin_email()], new.legal_name || ' signed the vendor agreement', 'Vendor agreement signed',
    public.ep('<b>' || public.h(new.legal_name) || '</b> signed the Vendor Network Agreement. Signed by ' || public.h(new.signer_name)
              || case when coalesce(new.signer_title, '') <> '' then ', ' || public.h(new.signer_title) else '' end || '.')
    || public.ep('They''re ready for introductions. The signed copy is on their vendor card.'),
    'See their profile', 'admin_agreement');
  return new;
exception when others then
  raise warning 'Orbyt agreement email skipped: %', sqlerrm;
  return new;
end $$;
drop trigger if exists agreements_notify on public.vendor_agreements;
create trigger agreements_notify after insert on public.vendor_agreements
  for each row execute function public.agreements_notify();

-- these helpers are for the database only
revoke execute on function public.orbyt_email(text[], text, text, text, text, text) from public, anon, authenticated;
revoke execute on function public.project_recipients(uuid) from public, anon, authenticated;
revoke execute on function public.vendor_email(uuid) from public, anon, authenticated;
revoke execute on function public.admin_email() from public, anon, authenticated;
revoke execute on function public.bids_notify() from public, anon, authenticated;
revoke execute on function public.profiles_notify() from public, anon, authenticated;
revoke execute on function public.members_notify() from public, anon, authenticated;
revoke execute on function public.projects_notify() from public, anon, authenticated;
revoke execute on function public.agreements_notify() from public, anon, authenticated;

-- Done. Next: sign up in the portal as ashleigh@orbytconnect.com, then run
-- make-me-admin.sql once to turn that account into the admin account.

-- ---------- Insurance by trade group: vendors upload, Ashleigh verifies, reminders run daily ----------
-- vendor's current certificate: {path, name, expires, uploadedAt}
alter table public.vendor_private add column if not exists insurance jsonb not null default '{}';
-- Ashleigh's check (only she can write vendor_admin)
alter table public.vendor_admin add column if not exists insurance_verified_path text;
alter table public.vendor_admin add column if not exists insurance_verified_at   timestamptz;
alter table public.vendor_admin add column if not exists insurance_expires       date;
alter table public.vendor_admin add column if not exists insurance_note          text;
alter table public.vendor_admin add column if not exists insurance_note_at       timestamptz;

create table if not exists public.insurance_reminders (
  vendor_id  uuid not null references public.vendors (id) on delete cascade,
  kind       text not null,
  sent_at    timestamptz not null default now(),
  primary key (vendor_id, kind)
);
alter table public.insurance_reminders enable row level security;
drop policy if exists insurance_reminders_admin on public.insurance_reminders;
create policy insurance_reminders_admin on public.insurance_reminders for select to authenticated using (public.is_admin());
grant select on public.insurance_reminders to authenticated;
revoke all on public.insurance_reminders from anon;

-- Trade groups. Keep these lists in step with INS_GROUPS in the portal code (src/live.js).
create or replace function public.insurance_trades(services text[], grp text) returns text[]
language sql immutable set search_path = '' as $$
  select coalesce(array_agg(s order by s), '{}') from unnest(coalesce(services, '{}')) s
  where lower(trim(s)) = any (case grp
    when 'high' then array['general contractor / remodeling','roofing','plumbing','electric','hvac','concrete','flooring','drywall',
                           'fencing','garage doors','appliance repair','solar panel cleaning','pest control','tree service']
    when 'mid'  then array['handyman','pool services','moving','junk removal','gutter cleaning','pressure washing','window cleaning',
                           'staging','landscaping']
    else array[]::text[] end)
$$;
create or replace function public.insurance_group(services text[]) returns text
language sql immutable set search_path = '' as $$
  select case when cardinality(public.insurance_trades(services, 'high')) > 0 then 'high'
              when cardinality(public.insurance_trades(services, 'mid'))  > 0 then 'mid' else 'low' end
$$;

-- Emails when a certificate comes in, when Ashleigh asks for a fix, and when she confirms it
create or replace function public.insurance_upload_notify() returns trigger language plpgsql security definer set search_path = '' as $$
declare vname text;
begin
  if coalesce(new.insurance ->> 'path', '') <> '' and new.insurance ->> 'path' is distinct from old.insurance ->> 'path' then
    select name into vname from public.vendors where id = new.vendor_id;
    perform public.orbyt_email(array[public.admin_email()], vname || ' uploaded their insurance', 'Insurance to check',
      public.ep('<b>' || public.h(vname) || '</b> uploaded a certificate of insurance'
        || case when coalesce(new.insurance ->> 'expires', '') <> '' then ', good through ' || public.h(to_char((new.insurance ->> 'expires')::date, 'FMMonth FMDD, YYYY')) else '' end || '.')
      || public.ep('Open it from your dashboard, check that Orbyt LLC is listed, and click Verified.'),
      'Check it now', 'admin_insurance');
  end if;
  return new;
exception when others then
  raise warning 'Orbyt insurance email skipped: %', sqlerrm;
  return new;
end $$;
drop trigger if exists insurance_upload_notify on public.vendor_private;
create trigger insurance_upload_notify after update of insurance on public.vendor_private
  for each row execute function public.insurance_upload_notify();

create or replace function public.insurance_check_notify() returns trigger language plpgsql security definer set search_path = '' as $$
declare v public.vendors%rowtype;
begin
  select * into v from public.vendors where id = new.vendor_id;
  if new.insurance_note_at is distinct from old.insurance_note_at and coalesce(new.insurance_note, '') <> '' then
    perform public.orbyt_email(array[public.vendor_email(v.id)], 'Your insurance certificate needs another look', 'One fix on your insurance',
      public.ep('Hi ' || public.h(public.first_name(v.contact_name)) || ', thanks for sending your certificate of insurance. It needs one change before I can mark it complete:')
      || public.ep('<i>' || public.h(new.insurance_note) || '</i>')
      || public.ep('Sign in to copy a ready-made request for your insurance agent, then upload the new certificate.'),
      'Upload a new certificate', 'insurance_fix');
  elsif new.insurance_verified_at is distinct from old.insurance_verified_at and new.insurance_verified_at is not null then
    perform public.orbyt_email(array[public.vendor_email(v.id)], 'Your insurance is all set', 'Insurance confirmed',
      public.ep('Hi ' || public.h(public.first_name(v.contact_name)) || ', your certificate of insurance is confirmed'
        || case when new.insurance_expires is not null then ', good through ' || to_char(new.insurance_expires, 'FMMonth FMDD, YYYY') else '' end
        || '. I''ll remind you before it expires.'),
      'Go to Orbyt', 'insurance_ok');
  end if;
  return new;
exception when others then
  raise warning 'Orbyt insurance email skipped: %', sqlerrm;
  return new;
end $$;
drop trigger if exists insurance_check_notify on public.vendor_admin;
create trigger insurance_check_notify after update of insurance_note_at, insurance_verified_at on public.vendor_admin
  for each row execute function public.insurance_check_notify();

-- Daily reminders: missing certificates, expiring soon, expired. Each one goes out once.
create or replace function public.insurance_reminders_run() returns integer language plpgsql security definer set search_path = '' as $$
declare
  r        record;
  grp      text;
  trades   text;
  cur      jsonb;
  has_file boolean;
  verified boolean;
  exp      date;
  due      date;
  n_up     integer;
  last_up  timestamptz;
  ask      text;
  sent     integer := 0;
begin
  for r in
    select v.id, v.name, v.services, v.contact_name, a.approved_at, a.insurance_verified_path, a.insurance_expires,
           a.insurance_note_at, coalesce(p.insurance, '{}'::jsonb) as insurance
      from public.vendors v
      join public.vendor_admin a on a.vendor_id = v.id and a.approved
      left join public.vendor_private p on p.vendor_id = v.id
      join public.profiles pr on pr.id = v.user_id and pr.status = 'active'
  loop
    grp := public.insurance_group(r.services);
    trades := lower(array_to_string(public.insurance_trades(r.services, grp), ', '));
    cur := r.insurance;
    has_file := coalesce(cur ->> 'path', '') <> ''
                and (r.insurance_note_at is null or r.insurance_note_at < coalesce((cur ->> 'uploadedAt')::timestamptz, '-infinity'));
    verified := has_file and r.insurance_verified_path = cur ->> 'path';
    exp := case when verified then r.insurance_expires else nullif(cur ->> 'expires', '')::date end;
    due := (coalesce(r.approved_at, now()) + interval '30 days')::date;

    if not has_file then
      -- up to four nudges, a week apart, starting two days after approval
      select count(*), max(sent_at) into n_up, last_up from public.insurance_reminders where vendor_id = r.id and kind like 'upload:%';
      if n_up < 4 and coalesce(r.approved_at, now()) < now() - interval '2 days' and (last_up is null or last_up < now() - interval '6 days') then
        ask := case grp
          when 'high' then 'Because you offer ' || public.h(trades) || ', Orbyt needs a certificate of insurance that names Orbyt LLC as an additional insured before I can send you introductions.'
          when 'mid'  then 'Because you offer ' || public.h(trades) || ', Orbyt needs a certificate of insurance that names Orbyt LLC as an additional insured by '
                           || to_char(due, 'FMMonth FMDD') || '. Introductions keep coming until then.'
          else 'Orbyt needs a current certificate of your general liability insurance' || ' by ' || to_char(due, 'FMMonth FMDD') || '.' end;
        perform public.orbyt_email(array[public.vendor_email(r.id)], 'Your Orbyt insurance certificate', 'Quick insurance step',
          public.ep('Hi ' || public.h(public.first_name(r.contact_name)) || ', ' || ask)
          || public.ep('Sign in to copy a ready-made email to your insurance agent. They can usually send the certificate the same day. Then upload it on your dashboard.'),
          'Upload my certificate', 'insurance_upload');
        insert into public.insurance_reminders (vendor_id, kind) values (r.id, 'upload:' || (n_up + 1)) on conflict do nothing;
        sent := sent + 1;
      end if;
    elsif exp is not null and exp < current_date then
      if not exists (select 1 from public.insurance_reminders where vendor_id = r.id and kind = 'expired:' || exp) then
        perform public.orbyt_email(array[public.vendor_email(r.id)], 'Your insurance certificate has expired', 'Time for a new certificate',
          public.ep('Hi ' || public.h(public.first_name(r.contact_name)) || ', the certificate of insurance on file with Orbyt expired on '
            || to_char(exp, 'FMMonth FMDD, YYYY') || '.'
            || case when grp <> 'low' then ' New introductions are paused until the renewed certificate is in.' else '' end)
          || public.ep('Ask your insurance agent for the renewed certificate (sign in to copy a ready-made request), then upload it on your dashboard.'),
          'Upload my certificate', 'insurance_expired');
        perform public.orbyt_email(array[public.admin_email()], r.name || '''s insurance expired', 'Insurance expired',
          public.ep('<b>' || public.h(r.name) || '</b>''s certificate of insurance expired on ' || to_char(exp, 'FMMonth FMDD, YYYY') || '. They''ve been asked to upload the renewal.'),
          'See their profile', 'admin_insurance');
        insert into public.insurance_reminders (vendor_id, kind) values (r.id, 'expired:' || exp) on conflict do nothing;
        sent := sent + 1;
      end if;
    elsif verified and exp is not null and exp <= current_date + 30 then
      if not exists (select 1 from public.insurance_reminders where vendor_id = r.id and kind = 'expiring:' || exp) then
        perform public.orbyt_email(array[public.vendor_email(r.id)], 'Your insurance renews soon', 'Insurance renewal coming up',
          public.ep('Hi ' || public.h(public.first_name(r.contact_name)) || ', the certificate of insurance on file with Orbyt is good through '
            || to_char(exp, 'FMMonth FMDD, YYYY') || '. Once your policy renews, please upload the new certificate so introductions keep coming.'),
          'Upload my certificate', 'insurance_expiring');
        insert into public.insurance_reminders (vendor_id, kind) values (r.id, 'expiring:' || exp) on conflict do nothing;
        sent := sent + 1;
      end if;
    end if;
  end loop;
  return sent;
end $$;
revoke execute on function public.insurance_reminders_run() from public, anon, authenticated;
revoke execute on function public.insurance_upload_notify() from public, anon, authenticated;
revoke execute on function public.insurance_check_notify() from public, anon, authenticated;

-- Run the reminders every morning (9:05am Pacific in summer, 8:05am in winter)
do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('orbyt-insurance-reminders', '5 16 * * *', 'select public.insurance_reminders_run()');
exception when others then
  raise warning 'Daily insurance reminders were not scheduled (%). In Supabase, turn on the pg_cron extension under Database, Extensions, then run this script again.', sqlerrm;
end $$;

-- ---------- Ashleigh can delete an agent or vendor (handy for test accounts) ----------
-- Removes the login and profile. For a vendor, also their vendor profile, bids, reviews and notes.
-- For an agent, their projects are deleted only when p_projects is true; otherwise they stay in Ashleigh's desk.
-- Terms of Use acceptance records are kept (with the email) as a record of what was agreed.
create or replace function public.admin_delete_account(p_user uuid default null, p_vendor uuid default null, p_projects boolean default false)
returns void language plpgsql security definer set search_path = '' as $$
declare vid uuid := p_vendor;
begin
  if not public.is_admin() then raise exception 'Only Orbyt can delete accounts.'; end if;
  if p_user is not null and p_user = auth.uid() then raise exception 'You can''t delete your own account.'; end if;
  if p_user is not null and exists (select 1 from public.profiles where id = p_user and role = 'admin') then
    raise exception 'Admin accounts can''t be deleted here.';
  end if;
  if vid is null and p_user is not null then select id into vid from public.vendors where user_id = p_user; end if;
  if p_user is null and vid is not null then select user_id into p_user from public.vendors where id = vid; end if;
  if vid is not null then
    delete from public.bids where vendor_id = vid;
    delete from public.vendors where id = vid;
  end if;
  if p_user is not null then
    if p_projects then delete from public.projects where agent_id = p_user; end if;
    delete from auth.users where id = p_user;
  end if;
end $$;
revoke execute on function public.admin_delete_account(uuid, uuid, boolean) from public, anon;
grant execute on function public.admin_delete_account(uuid, uuid, boolean) to authenticated;

-- ---------- Keep projects and vendor records in step when someone updates their details ----------
create or replace function public.profiles_sync() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.role = 'agent' then
    update public.projects set
      agent_name  = case when new.full_name is distinct from old.full_name and coalesce(new.full_name, '') <> '' then new.full_name else agent_name end,
      agent_phone = case when new.phone is distinct from old.phone then new.phone else agent_phone end,
      brokerage   = case when new.brokerage is distinct from old.brokerage then new.brokerage else brokerage end,
      agent_email = case when new.email is distinct from old.email then new.email else agent_email end
    where agent_id = new.id;
  end if;
  if new.role = 'vendor' then
    update public.vendors set
      contact_name = case when new.full_name is distinct from old.full_name and coalesce(new.full_name, '') <> '' then new.full_name else contact_name end,
      phone        = case when new.phone is distinct from old.phone then new.phone else phone end,
      email        = case when new.email is distinct from old.email then new.email else email end
    where user_id = new.id;
  end if;
  if new.email is distinct from old.email then
    update public.project_members set email = new.email where user_id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists profiles_sync on public.profiles;
create trigger profiles_sync after update of full_name, phone, brokerage, email on public.profiles
  for each row execute function public.profiles_sync();

-- When a login email changes (the person confirmed a new address, or Ashleigh changed it), update their profile too
create or replace function public.auth_email_sync() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.email is distinct from old.email and new.email is not null then
    update public.profiles set email = lower(new.email) where id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists on_auth_email_change on auth.users;
create trigger on_auth_email_change after update of email on auth.users
  for each row execute function public.auth_email_sync();

-- Ashleigh changes someone's login email for them (no confirmation step, so double-check the spelling)
create or replace function public.admin_set_email(p_user uuid, p_email text)
returns void language plpgsql security definer set search_path = '' as $$
declare em text := lower(trim(p_email));
begin
  if not public.is_admin() then raise exception 'Only Orbyt can change someone''s login email.'; end if;
  if em is null or em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That email doesn''t look right.'; end if;
  if exists (select 1 from auth.users where lower(email) = em and id <> p_user) then
    raise exception 'That email already has an Orbyt account.';
  end if;
  update auth.users set email = em, updated_at = now() where id = p_user;
  if to_regclass('auth.identities') is not null then
    execute 'update auth.identities set identity_data = identity_data || jsonb_build_object(''email'', $1), updated_at = now()
             where user_id = $2 and provider = ''email''' using em, p_user;
  end if;
end $$;
revoke execute on function public.admin_set_email(uuid, text) from public, anon;
grant execute on function public.admin_set_email(uuid, text) to authenticated;
revoke execute on function public.profiles_sync() from public, anon, authenticated;
revoke execute on function public.auth_email_sync() from public, anon, authenticated;

-- ---------- Bid request reminders: a nudge to the vendor after 2 days, and a daily heads-up to Ashleigh ----------
create table if not exists public.reminders_sent (
  key      text primary key,
  sent_at  timestamptz not null default now()
);
alter table public.reminders_sent enable row level security;
drop policy if exists reminders_sent_admin on public.reminders_sent;
create policy reminders_sent_admin on public.reminders_sent for select to authenticated using (public.is_admin());
grant select on public.reminders_sent to authenticated;
revoke all on public.reminders_sent from anon;

create or replace function public.bid_reminders_run() returns integer language plpgsql security definer set search_path = '' as $$
declare
  r      record;
  k      text;
  lines  text := '';
  n      integer := 0;
begin
  for r in
    select b.id, b.status, b.category, p.address, p.agent_name, p.target_date, v.id as vid, v.name as vname, v.contact_name,
           coalesce(case when b.status = 'changes' then b.changes_at end, b.introduced_at, b.requested_at) as since
      from public.bids b
      join public.projects p on p.id = b.project_id and not p.listed
      join public.vendors v on v.id = b.vendor_id
     where b.status in ('requested', 'changes')
  loop
    continue when r.since is null or r.since > now() - interval '2 days';
    k := 'bid:' || r.id || ':' || r.status || ':' || floor(extract(epoch from r.since))::bigint;
    continue when exists (select 1 from public.reminders_sent where key = k);
    perform public.orbyt_email(array[public.vendor_email(r.vid)],
      'Reminder: ' || r.category || ' bid for ' || r.address,
      case when r.status = 'changes' then 'A bid update is waiting' else 'A bid request is waiting' end,
      public.ep('Hi ' || public.h(public.first_name(coalesce(r.contact_name, r.vname))) || ', ' || public.h(r.agent_name)
        || case when r.status = 'changes' then ' is still waiting on the change to your ' else ' is still waiting on your ' end
        || public.h(lower(r.category)) || ' bid for <b>' || public.h(r.address) || '</b>'
        || case when r.target_date is not null then ', with a target date of ' || public.date_text(r.target_date) else '' end || '.')
      || public.ep('Sign in to send it. If you can''t take this one, let them know there so they can line up someone else.'),
      'Send my bid', 'bid_reminder');
    insert into public.reminders_sent (key) values (k) on conflict do nothing;
    lines := lines || '<li>' || public.h(r.vname) || ': ' || public.h(r.category) || ' at ' || public.h(r.address)
             || case when r.status = 'changes' then ' (change requested)' else '' end || '</li>';
    n := n + 1;
  end loop;
  if n > 0 then
    perform public.orbyt_email(array[public.admin_email()],
      n || case when n = 1 then ' bid request is' else ' bid requests are' end || ' waiting on vendors',
      'Bids waiting on vendors',
      public.ep('These have gone 2 days without a bid. Each vendor just got a reminder:')
      || '<ul style="font-size:15px;line-height:1.6;margin:0 0 16px;padding-left:20px">' || lines || '</ul>'
      || public.ep('If one stays quiet, you can nudge them from your dashboard or introduce someone else.'),
      'Open your dashboard', 'admin_bid_reminder');
  end if;
  return n;
end $$;
revoke execute on function public.bid_reminders_run() from public, anon, authenticated;

-- Run it every morning, alongside the insurance reminders
do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('orbyt-bid-reminders', '10 16 * * *', 'select public.bid_reminders_run()');
exception when others then
  raise warning 'Daily bid reminders were not scheduled (%). In Supabase, turn on the pg_cron extension under Database, Extensions, then run this script again.', sqlerrm;
end $$;

-- ---------- Vendor Review & Agree details (business name, authority, marketing opt-out) ----------
alter table public.vendor_private add column if not exists legal_name        text;
alter table public.vendor_private add column if not exists dba               text;
alter table public.vendor_private add column if not exists business_type     text;
alter table public.vendor_private add column if not exists signer_title      text;
alter table public.vendor_private add column if not exists marketing_opt_out boolean not null default false;

-- what each acceptance was agreed on behalf of
alter table public.terms_acceptances add column if not exists on_behalf_of        text;
alter table public.terms_acceptances add column if not exists signer_title        text;
alter table public.terms_acceptances add column if not exists authority_confirmed boolean not null default false;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  m        jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  r        text  := case when m ->> 'role' = 'vendor' then 'vendor' else 'agent' end;
  em       text  := lower(new.email);
  invited  boolean;
  v_id     uuid;
begin
  -- agents who are already on a project (shared with them, or imported/added by Orbyt under their email)
  -- and vendors Orbyt already approved skip the approval wait
  invited := (r = 'agent' and (
    exists (select 1 from public.project_members where lower(email) = em)
    or exists (select 1 from public.default_shares where lower(email) = em)
    or exists (select 1 from public.projects where agent_id is null and lower(agent_email) = em)))
    or (r = 'vendor' and exists (select 1 from public.vendors v join public.vendor_admin a on a.vendor_id = v.id
                                 where v.user_id is null and lower(v.email) = em and a.approved));

  insert into public.profiles (id, role, status, full_name, email, phone, brokerage, areas, approved_at)
  values (new.id, r, case when invited then 'active' else 'pending' end,
          nullif(trim(m ->> 'full_name'), ''), em, m ->> 'phone', m ->> 'brokerage',
          public.jsonb_text_array(m -> 'areas'), case when invited then now() end)
  on conflict (id) do nothing;

  update public.project_members set user_id = new.id where user_id is null and lower(email) = em;
  if r = 'agent' then
    update public.projects set agent_id = new.id where agent_id is null and lower(agent_email) = em;
  end if;

  if r = 'vendor' then
    select id into v_id from public.vendors where user_id is null and lower(email) = em limit 1;
    if v_id is null then
      insert into public.vendors (user_id, name, contact_name, email, phone, website, services, areas,
                                  years_in_business, team_size, lead_time, works_with_agents, portfolio_url, source)
      values (new.id, coalesce(nullif(trim(m ->> 'company'), ''), nullif(trim(m ->> 'full_name'), ''), em),
              m ->> 'full_name', em, m ->> 'phone', m ->> 'website',
              public.jsonb_text_array(m -> 'services'), public.jsonb_text_array(m -> 'areas'),
              m ->> 'years_in_business', m ->> 'team_size', m ->> 'lead_time',
              m ->> 'works_with_agents', m ->> 'portfolio_url', 'Portal sign-up')
      returning id into v_id;
      insert into public.vendor_admin (vendor_id) values (v_id) on conflict do nothing;
    else
      update public.vendors set user_id = new.id where id = v_id;
      insert into public.vendor_admin (vendor_id) values (v_id) on conflict do nothing;
    end if;
    insert into public.vendor_private (vendor_id, references_text, heard_about, signup_notes, promo_interest,
                                       legal_name, dba, business_type, signer_title, marketing_opt_out)
    values (v_id, m ->> 'references', m ->> 'heard_about', m ->> 'signup_notes', m ->> 'promo_interest',
            nullif(trim(m ->> 'legal_name'), ''), nullif(trim(m ->> 'dba'), ''), nullif(trim(m ->> 'business_type'), ''),
            nullif(trim(m ->> 'signer_title'), ''), coalesce((m ->> 'marketing_opt_out')::boolean, false))
    on conflict (vendor_id) do update set
      references_text   = coalesce(excluded.references_text, public.vendor_private.references_text),
      heard_about       = coalesce(excluded.heard_about,     public.vendor_private.heard_about),
      signup_notes      = coalesce(excluded.signup_notes,    public.vendor_private.signup_notes),
      promo_interest    = coalesce(excluded.promo_interest,  public.vendor_private.promo_interest),
      legal_name        = coalesce(excluded.legal_name,      public.vendor_private.legal_name),
      dba               = coalesce(excluded.dba,             public.vendor_private.dba),
      business_type     = coalesce(excluded.business_type,   public.vendor_private.business_type),
      signer_title      = coalesce(excluded.signer_title,    public.vendor_private.signer_title),
      marketing_opt_out = excluded.marketing_opt_out or public.vendor_private.marketing_opt_out;
  end if;
  -- Terms of Use accepted with the checkbox on the sign-up form
  if (m ->> 'terms_version') like r || '-terms-%' then
    insert into public.terms_acceptances (user_id, email, role, version, source, user_agent, on_behalf_of, signer_title, authority_confirmed)
    values (new.id, em, r, m ->> 'terms_version', 'signup', left(m ->> 'user_agent', 300),
            case when r = 'vendor' then nullif(trim(m ->> 'legal_name'), '') end,
            case when r = 'vendor' then nullif(trim(m ->> 'signer_title'), '') end,
            r = 'vendor' and coalesce((m ->> 'authority')::boolean, false));
  end if;
  return new;
end $$;

-- agree in the portal (people who joined before the checkbox, or after the terms change).
-- Vendors also confirm the business details and their authority to agree for it.
drop function if exists public.accept_terms(text, text);
create or replace function public.accept_terms(p_version text, p_user_agent text default null, p_details jsonb default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare r text; em text; new_id uuid; vid uuid; d jsonb := coalesce(p_details, '{}'::jsonb); ln text;
begin
  select role, lower(email) into r, em from public.profiles where id = auth.uid();
  if r is null or r not in ('agent', 'vendor') then raise exception 'Only agents and vendors accept these terms'; end if;
  if p_version is null or p_version not like r || '-terms-%' then raise exception 'Those terms are not for this account'; end if;
  ln := nullif(trim(d ->> 'legal_name'), '');
  if r = 'vendor' and p_details is not null then
    if ln is null then raise exception 'You can only agree once the legal business name is filled in.'; end if;
    if coalesce((d ->> 'authority')::boolean, false) = false then raise exception 'You can only agree once you confirm you have authority for the business.'; end if;
    select id into vid from public.vendors where user_id = auth.uid();
    if vid is not null then
      insert into public.vendor_private (vendor_id) values (vid) on conflict do nothing;
      update public.vendor_private set
        legal_name    = ln,
        dba           = nullif(trim(d ->> 'dba'), ''),
        business_type = coalesce(nullif(trim(d ->> 'business_type'), ''), business_type),
        signer_title  = coalesce(nullif(trim(d ->> 'signer_title'), ''), signer_title)
      where vendor_id = vid;
    end if;
  end if;
  insert into public.terms_acceptances (user_id, email, role, version, source, ip, user_agent, on_behalf_of, signer_title, authority_confirmed)
  values (auth.uid(), em, r, p_version, 'portal', public.request_ip(), left(p_user_agent, 300),
          case when r = 'vendor' then ln end,
          case when r = 'vendor' then nullif(trim(d ->> 'signer_title'), '') end,
          r = 'vendor' and coalesce((d ->> 'authority')::boolean, false))
  returning id into new_id;
  return new_id;
end $$;
revoke execute on function public.accept_terms(text, text, jsonb) from public, anon;
grant execute on function public.accept_terms(text, text, jsonb) to authenticated;

-- ---------- Review requests to past clients ----------
-- reviews now say where they came from: a job booked through Orbyt, or a past client a vendor invited
alter table public.reviews add column if not exists source             text not null default 'booked';
alter table public.reviews add column if not exists reviewer_email     text;
alter table public.reviews add column if not exists reviewer_brokerage text;
alter table public.reviews add column if not exists work_when          text;
do $$ begin
  alter table public.reviews add constraint reviews_source_check check (source in ('booked', 'past_client'));
exception when duplicate_object then null; end $$;

create table if not exists public.review_requests (
  id            uuid primary key default gen_random_uuid(),
  vendor_id     uuid not null references public.vendors (id) on delete cascade,
  agent_name    text not null,
  agent_email   text not null,
  note          text,
  token         text not null unique default (replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')),
  created_at    timestamptz not null default now(),
  reminded_at   timestamptz,
  completed_at  timestamptz,
  review_id     uuid references public.reviews (id) on delete set null,
  submit_ip     text
);
create unique index if not exists review_requests_vendor_email_idx on public.review_requests (vendor_id, lower(agent_email));
alter table public.review_requests enable row level security;
-- nobody reads the table directly (the links are private). The functions below are the only way in.
revoke all on public.review_requests from anon, authenticated;

-- the most review requests one vendor can send
create or replace function public.review_request_limit() returns integer language sql immutable set search_path = '' as $$ select 10 $$;

-- Same branded email as orbyt_email, with the button pointing at a specific link
create or replace function public.orbyt_email_link(p_to text[], p_subject text, p_heading text, p_body text, p_button text, p_kind text, p_link text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  cfg  jsonb;
  k    text;
  addr text;
  html text;
  rid  bigint;
begin
  select value into cfg from public.settings where key = 'email';
  if cfg is null or coalesce((cfg ->> 'enabled')::boolean, false) = false then return; end if;
  html := '<div style="background:#F6F4EA;padding:32px 16px;font-family:Arial,Helvetica,sans-serif;color:#18314F">'
       || '<div style="max-width:520px;margin:0 auto;background:#ffffff;border-radius:12px;padding:32px">'
       || '<img src="' || (cfg ->> 'logo') || '" width="180" alt="Orbyt" style="display:block;width:180px;max-width:100%;height:auto;border:0;margin:0 0 24px">'
       || '<h1 style="font-size:22px;font-weight:500;margin:0 0 12px;color:#18314F">' || public.h(p_heading) || '</h1>'
       || p_body
       || '<p style="margin:20px 0 24px"><a href="' || public.h(coalesce(p_link, cfg ->> 'portal_url')) || '" style="background:#18314F;color:#ffffff;text-decoration:none;padding:12px 24px;border-radius:999px;font-size:15px;display:inline-block">' || public.h(p_button) || '</a></p>'
       || '<p style="font-size:14px;line-height:1.6;color:#2C4260;margin:0">Questions? Just reply. Ashleigh at Orbyt</p>'
       || '</div></div>';
  select decrypted_secret into k from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  for addr in select distinct lower(trim(x)) from unnest(p_to) as x where x is not null and trim(x) like '%_@_%.%' loop
    begin
      if k is null then
        insert into public.email_log (kind, to_email, subject, status) values (p_kind, addr, p_subject, 'not sent: Resend key missing');
        continue;
      end if;
      select net.http_post(
        url     := 'https://api.resend.com/emails',
        headers := jsonb_build_object('Authorization', 'Bearer ' || k, 'Content-Type', 'application/json'),
        body    := jsonb_build_object('from', cfg ->> 'from', 'to', jsonb_build_array(addr), 'reply_to', cfg ->> 'admin',
                                      'subject', p_subject, 'html', html)
      ) into rid;
      insert into public.email_log (kind, to_email, subject, status, request_id) values (p_kind, addr, p_subject, 'queued', rid);
    exception when others then
      raise warning 'Orbyt email not sent to %: %', addr, sqlerrm;
    end;
  end loop;
exception when others then
  raise warning 'Orbyt email not sent: %', sqlerrm;
end $$;
revoke execute on function public.orbyt_email_link(text[], text, text, text, text, text, text) from public, anon, authenticated;

create or replace function public.review_link(p_token text) returns text language sql stable security definer set search_path = '' as $$
  select coalesce((select value ->> 'portal_url' from public.settings where key = 'email'), 'https://portal.orbytconnect.com') || '/?review=' || p_token
$$;
revoke execute on function public.review_link(text) from public, anon, authenticated;

-- the email an invited agent gets (first send, or the reminder)
create or replace function public.review_request_email(p_id uuid, p_reminder boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare q public.review_requests%rowtype; v public.vendors%rowtype;
begin
  select * into q from public.review_requests where id = p_id;
  select * into v from public.vendors where id = q.vendor_id;
  perform public.orbyt_email_link(array[q.agent_email],
    case when p_reminder then 'Reminder: ' else '' end || v.name || ' asked for your review',
    'Would you review ' || v.name || '?',
    public.ep('Hi ' || public.h(public.first_name(q.agent_name)) || ',')
    || public.ep(public.h(v.name) || ' just joined Orbyt, a vendor network for San Diego agents, and mentioned you''ve worked together. Would you share a quick review of your experience? It takes about two minutes, and you don''t need an account.')
    || case when coalesce(trim(q.note), '') <> '' then
         '<p style="font-size:15px;line-height:1.6;margin:0 0 12px;padding:10px 14px;border-left:3px solid #E3DFD0;color:#2C4260"><i>'
         || public.h(q.note) || '</i><br><span style="font-size:13px">' || public.h(coalesce(v.contact_name, v.name)) || '</span></p>'
       else '' end
    || public.ep('Your review helps other agents find good people. Thanks for taking a minute.'),
    'Leave a review', case when p_reminder then 'review_reminder' else 'review_request' end, public.review_link(q.token));
end $$;
revoke execute on function public.review_request_email(uuid, boolean) from public, anon, authenticated;

-- Vendor sends invites: p_invites is a list of {"name": "...", "email": "..."}
create or replace function public.send_review_requests(p_invites jsonb, p_note text default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  vid    uuid := public.my_vendor_id();
  used   integer;
  x      jsonb;
  nm     text;
  em     text;
  own    text;
  new_id uuid;
  n      integer := 0;
begin
  if vid is null or not public.is_active() then raise exception 'You can only send review requests from an approved vendor account.'; end if;
  if not exists (select 1 from public.vendor_admin where vendor_id = vid and approved) then
    raise exception 'You can only send review requests once Ashleigh approves your account.';
  end if;
  if jsonb_typeof(p_invites) <> 'array' or jsonb_array_length(p_invites) = 0 then raise exception 'You can only send a request with at least one name and email.'; end if;
  select count(*) into used from public.review_requests where vendor_id = vid;
  if used + jsonb_array_length(p_invites) > public.review_request_limit() then
    raise exception 'You can only invite % agents in all. You have % left.', public.review_request_limit(), greatest(public.review_request_limit() - used, 0);
  end if;
  own := lower(coalesce(public.vendor_email(vid), ''));
  for x in select * from jsonb_array_elements(p_invites) loop
    nm := nullif(trim(x ->> 'name'), '');
    em := lower(trim(coalesce(x ->> 'email', '')));
    if nm is null then raise exception 'You can only send a request with a name for each agent.'; end if;
    if em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'You can only send to a valid email. Check %.', coalesce(x ->> 'email', 'the email'); end if;
    if em = own or em = public.my_email() then raise exception 'You can only invite other people, not your own email.'; end if;
    if em = lower(coalesce(public.admin_email(), '')) then raise exception 'You can only invite agents you''ve worked with.'; end if;
    if exists (select 1 from public.review_requests where vendor_id = vid and lower(agent_email) = em) then
      raise exception 'You can only invite each agent once. % already has a request.', em;
    end if;
    insert into public.review_requests (vendor_id, agent_name, agent_email, note)
    values (vid, left(nm, 120), em, nullif(left(trim(coalesce(p_note, '')), 600), ''))
    returning id into new_id;
    perform public.review_request_email(new_id, false);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.send_review_requests(jsonb, text) from public, anon;
grant execute on function public.send_review_requests(jsonb, text) to authenticated;

-- What the portal shows: a vendor sees their own requests, Ashleigh sees all. Never the private link.
create or replace function public.review_requests_list()
returns table (id uuid, vendor_id uuid, agent_name text, agent_email text, note text, created_at timestamptz,
               reminded_at timestamptz, completed_at timestamptz, review_id uuid)
language sql stable security definer set search_path = '' as $$
  select q.id, q.vendor_id, q.agent_name, q.agent_email, q.note, q.created_at, q.reminded_at, q.completed_at, q.review_id
    from public.review_requests q
   where public.is_admin() or (public.is_active() and q.vendor_id = public.my_vendor_id())
   order by q.created_at
$$;
revoke execute on function public.review_requests_list() from public, anon;
grant execute on function public.review_requests_list() to authenticated;

-- The review page behind the private link (no login)
create or replace function public.review_request_get(p_token text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('vendor', v.name, 'services', v.services, 'agent_name', q.agent_name,
                            'done', q.completed_at is not null)
    from public.review_requests q join public.vendors v on v.id = q.vendor_id
   where q.token = p_token and length(coalesce(p_token, '')) >= 32
$$;
revoke execute on function public.review_request_get(text) from public;
grant execute on function public.review_request_get(text) to anon, authenticated;

create or replace function public.review_request_submit(p_token text, p_rating integer, p_comment text, p_name text,
                                                        p_brokerage text, p_when text)
returns void language plpgsql security definer set search_path = '' as $$
declare q public.review_requests%rowtype; v public.vendors%rowtype; rid uuid;
begin
  select * into q from public.review_requests where token = p_token and length(coalesce(p_token, '')) >= 32 for update;
  if q.id is null then raise exception 'This review link isn''t active.'; end if;
  if q.completed_at is not null then raise exception 'This review has already been sent. Thank you!'; end if;
  if p_rating is null or p_rating not between 1 and 5 then raise exception 'Pick a star rating from 1 to 5.'; end if;
  if coalesce(trim(p_comment), '') = '' then raise exception 'Add a few words about the work.'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Add your name.'; end if;
  if coalesce(trim(p_brokerage), '') = '' then raise exception 'Add your brokerage.'; end if;
  insert into public.reviews (vendor_id, agent_name, rating, comment, approved, source, reviewer_email, reviewer_brokerage, work_when)
  values (q.vendor_id, left(trim(p_name), 120), p_rating, left(trim(p_comment), 2000), false, 'past_client',
          q.agent_email, left(trim(p_brokerage), 160), nullif(left(trim(coalesce(p_when, '')), 40), ''))
  returning id into rid;
  update public.review_requests set completed_at = now(), review_id = rid, submit_ip = public.request_ip() where id = q.id;
  select * into v from public.vendors where id = q.vendor_id;
  perform public.orbyt_email(array[public.admin_email()],
    'New review to approve: ' || v.name, 'A past client reviewed ' || v.name,
    public.ep('<b>' || public.h(trim(p_name)) || '</b> (' || public.h(trim(p_brokerage)) || ', ' || public.h(q.agent_email) || ') gave '
      || public.h(v.name) || ' ' || p_rating || case when p_rating = 1 then ' star' else ' stars' end
      || case when coalesce(trim(p_when), '') <> '' then ' for work in ' || public.h(trim(p_when)) else '' end || '.')
    || public.ep('<i>' || public.h(left(trim(p_comment), 600)) || '</i>')
    || public.ep('Check that it''s a real agent, then approve it from your dashboard. Honest critical reviews get approved too.'),
    'Review it', 'admin_review');
end $$;
revoke execute on function public.review_request_submit(text, integer, text, text, text, text) from public;
grant execute on function public.review_request_submit(text, integer, text, text, text, text) to anon, authenticated;

-- One reminder, 5 days after the first email, if they haven't reviewed yet
create or replace function public.review_request_reminders_run() returns integer language plpgsql security definer set search_path = '' as $$
declare r record; n integer := 0;
begin
  for r in select id from public.review_requests
            where completed_at is null and reminded_at is null and created_at <= now() - interval '5 days'
  loop
    perform public.review_request_email(r.id, true);
    update public.review_requests set reminded_at = now() where id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.review_request_reminders_run() from public, anon, authenticated;

do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('orbyt-review-reminders', '15 16 * * *', 'select public.review_request_reminders_run()');
exception when others then
  raise warning 'Daily review reminders were not scheduled (%). In Supabase, turn on the pg_cron extension under Database, Extensions, then run this script again.', sqlerrm;
end $$;

-- ---------- Removing a service from a project ----------
-- Remove a service from a project (the client booked it on their own). Ashleigh or an agent on the project can do it,
-- as long as nobody is chosen or booked for it and the home isn't listed yet. Open requests close (vendors who already
-- bid get the usual "went another way" email). When an agent does it, Ashleigh gets an email.
create or replace function public.remove_project_service(p_project uuid, p_category text)
returns void language plpgsql security definer set search_path = '' as $$
declare p public.projects%rowtype; who text; n integer;
begin
  select * into p from public.projects where id = p_project for update;
  if p.id is null or not (public.is_admin() or public.on_project(p.id)) then
    raise exception 'You can only remove a service from a project you''re on.';
  end if;
  if p.listed then raise exception 'You can only remove a service before the home is listed.'; end if;
  if not (p_category = any (p.categories)) then return; end if;
  if exists (select 1 from public.bids where project_id = p.id and category = p_category and status in ('chosen', 'selected')) then
    raise exception 'You can only remove a service that nobody is booked for yet.';
  end if;
  perform set_config('orbyt.service_removal', 'on', true);
  update public.bids set status = 'passed'
   where project_id = p.id and category = p_category and status in ('requested', 'submitted', 'changes');
  get diagnostics n = row_count;
  perform set_config('orbyt.service_removal', 'off', true);
  update public.projects set categories = array_remove(categories, p_category) where id = p.id;
  if not public.is_admin() then
    select coalesce(nullif(full_name, ''), email) into who from public.profiles where id = auth.uid();
    perform public.orbyt_email(array[public.admin_email()],
      coalesce(who, 'An agent') || ' removed ' || lower(p_category) || ' from ' || p.address,
      'A service came off a project',
      public.ep('<b>' || public.h(coalesce(who, 'An agent')) || '</b> removed <b>' || public.h(lower(p_category)) || '</b> from '
        || public.h(p.address) || ', so the client is handling it on their own.')
      || public.ep(case when n = 0 then 'No vendor requests were open for it.'
                        when n = 1 then '1 open request closed.'
                        else n || ' open requests closed.' end),
      'Open your dashboard', 'admin_service_removed');
  end if;
end $$;
revoke execute on function public.remove_project_service(uuid, text) from public, anon;
grant execute on function public.remove_project_service(uuid, text) to authenticated;

-- ---------- update 12: portfolios, home details, referrals ----------

alter table public.vendors          add column if not exists instagram          text;
alter table public.vendors          add column if not exists portfolio_pdf      text;
alter table public.vendors          add column if not exists portfolio_pdf_name text;
alter table public.projects         add column if not exists sqft               integer check (sqft is null or sqft between 1 and 100000);
alter table public.project_private  add column if not exists list_price         numeric check (list_price is null or list_price >= 0);
alter table public.profiles         add column if not exists referred_by        uuid references public.profiles (id) on delete set null;

-- the referrer is set only from the sign-up link, never edited afterwards from the portal
create or replace function public.profiles_ref_guard() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null and not public.is_admin() and new.referred_by is distinct from old.referred_by then
    raise exception 'Only Orbyt can change who referred you.';
  end if;
  return new;
end $$;
drop trigger if exists profiles_ref_guard on public.profiles;
create trigger profiles_ref_guard before update of referred_by on public.profiles
  for each row execute function public.profiles_ref_guard();
revoke execute on function public.profiles_ref_guard() from public, anon, authenticated;

-- how many people joined from someone's link (anyone can see their own count)
create or replace function public.my_referral_count() returns integer language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.profiles where referred_by = auth.uid()
$$;
revoke execute on function public.my_referral_count() from public, anon;
grant execute on function public.my_referral_count() to authenticated;

-- sign-ups now save Instagram and the referral code
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  m        jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  r        text  := case when m ->> 'role' = 'vendor' then 'vendor' else 'agent' end;
  em       text  := lower(new.email);
  invited  boolean;
  v_id     uuid;
begin
  -- agents who are already on a project (shared with them, or imported/added by Orbyt under their email)
  -- and vendors Orbyt already approved skip the approval wait
  invited := (r = 'agent' and (
    exists (select 1 from public.project_members where lower(email) = em)
    or exists (select 1 from public.default_shares where lower(email) = em)
    or exists (select 1 from public.projects where agent_id is null and lower(agent_email) = em)))
    or (r = 'vendor' and exists (select 1 from public.vendors v join public.vendor_admin a on a.vendor_id = v.id
                                 where v.user_id is null and lower(v.email) = em and a.approved));

  insert into public.profiles (id, role, status, full_name, email, phone, brokerage, areas, approved_at)
  values (new.id, r, case when invited then 'active' else 'pending' end,
          nullif(trim(m ->> 'full_name'), ''), em, m ->> 'phone', m ->> 'brokerage',
          public.jsonb_text_array(m -> 'areas'), case when invited then now() end)
  on conflict (id) do nothing;

  -- who referred them: the ref code from their sign-up link is the first 8 characters of the referrer's account id
  if coalesce(m ->> 'ref', '') ~ '^[0-9a-f]{8}$' then
    update public.profiles set referred_by = (select p.id from public.profiles p where p.id::text like (m ->> 'ref') || '%' and p.id <> new.id limit 1)
     where id = new.id and referred_by is null;
  end if;

  update public.project_members set user_id = new.id where user_id is null and lower(email) = em;
  if r = 'agent' then
    update public.projects set agent_id = new.id where agent_id is null and lower(agent_email) = em;
  end if;

  if r = 'vendor' then
    select id into v_id from public.vendors where user_id is null and lower(email) = em limit 1;
    if v_id is null then
      insert into public.vendors (user_id, name, contact_name, email, phone, website, services, areas,
                                  years_in_business, team_size, lead_time, works_with_agents, portfolio_url, instagram, source)
      values (new.id, coalesce(nullif(trim(m ->> 'company'), ''), nullif(trim(m ->> 'full_name'), ''), em),
              m ->> 'full_name', em, m ->> 'phone', m ->> 'website',
              public.jsonb_text_array(m -> 'services'), public.jsonb_text_array(m -> 'areas'),
              m ->> 'years_in_business', m ->> 'team_size', m ->> 'lead_time',
              m ->> 'works_with_agents', nullif(trim(m ->> 'portfolio_url'), ''), nullif(trim(m ->> 'instagram'), ''), 'Portal sign-up')
      returning id into v_id;
      insert into public.vendor_admin (vendor_id) values (v_id) on conflict do nothing;
    else
      update public.vendors set user_id = new.id,
             website       = coalesce(website, nullif(trim(m ->> 'website'), '')),
             portfolio_url = coalesce(portfolio_url, nullif(trim(m ->> 'portfolio_url'), '')),
             instagram     = coalesce(instagram, nullif(trim(m ->> 'instagram'), ''))
       where id = v_id;
      insert into public.vendor_admin (vendor_id) values (v_id) on conflict do nothing;
    end if;
    insert into public.vendor_private (vendor_id, references_text, heard_about, signup_notes, promo_interest,
                                       legal_name, dba, business_type, signer_title, marketing_opt_out)
    values (v_id, m ->> 'references', m ->> 'heard_about', m ->> 'signup_notes', m ->> 'promo_interest',
            nullif(trim(m ->> 'legal_name'), ''), nullif(trim(m ->> 'dba'), ''), nullif(trim(m ->> 'business_type'), ''),
            nullif(trim(m ->> 'signer_title'), ''), coalesce((m ->> 'marketing_opt_out')::boolean, false))
    on conflict (vendor_id) do update set
      references_text   = coalesce(excluded.references_text, public.vendor_private.references_text),
      heard_about       = coalesce(excluded.heard_about,     public.vendor_private.heard_about),
      signup_notes      = coalesce(excluded.signup_notes,    public.vendor_private.signup_notes),
      promo_interest    = coalesce(excluded.promo_interest,  public.vendor_private.promo_interest),
      legal_name        = coalesce(excluded.legal_name,      public.vendor_private.legal_name),
      dba               = coalesce(excluded.dba,             public.vendor_private.dba),
      business_type     = coalesce(excluded.business_type,   public.vendor_private.business_type),
      signer_title      = coalesce(excluded.signer_title,    public.vendor_private.signer_title),
      marketing_opt_out = excluded.marketing_opt_out or public.vendor_private.marketing_opt_out;
  end if;
  -- Terms of Use accepted with the checkbox on the sign-up form
  if (m ->> 'terms_version') like r || '-terms-%' then
    insert into public.terms_acceptances (user_id, email, role, version, source, user_agent, on_behalf_of, signer_title, authority_confirmed)
    values (new.id, em, r, m ->> 'terms_version', 'signup', left(m ->> 'user_agent', 300),
            case when r = 'vendor' then nullif(trim(m ->> 'legal_name'), '') end,
            case when r = 'vendor' then nullif(trim(m ->> 'signer_title'), '') end,
            r = 'vendor' and coalesce((m ->> 'authority')::boolean, false));
  end if;
  return new;
end $$;

-- ---------- update 13: home team cards for buyers ----------

alter table public.project_private add column if not exists client_email text;
alter table public.project_private add column if not exists client_phone text;

-- one card per agent: the short link name and what's on the card
create table if not exists public.home_cards (
  agent_id    uuid primary key references public.profiles (id) on delete cascade,
  slug        text not null unique check (slug ~ '^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$'),
  settings    jsonb not null default '{}',
  logo        text,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
alter table public.home_cards enable row level security;
drop policy if exists home_cards_own on public.home_cards;
create policy home_cards_own on public.home_cards for select to authenticated
  using (agent_id = auth.uid() or public.is_admin());
drop policy if exists home_cards_admin on public.home_cards;
create policy home_cards_admin on public.home_cards for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
revoke all on public.home_cards from anon;
grant select on public.home_cards to authenticated;

-- every request that comes in from a card (also used to slow down anyone sending too many)
create table if not exists public.home_card_requests (
  id           uuid primary key default gen_random_uuid(),
  agent_id     uuid references public.profiles (id) on delete cascade,
  project_id   uuid references public.projects (id) on delete set null,
  client_name  text,
  client_email text,
  client_phone text,
  ip           text,
  created_at   timestamptz not null default now()
);
alter table public.home_card_requests enable row level security;
drop policy if exists home_card_requests_read on public.home_card_requests;
create policy home_card_requests_read on public.home_card_requests for select to authenticated
  using (agent_id = auth.uid() or public.is_admin());
revoke all on public.home_card_requests from anon;
grant select on public.home_card_requests to authenticated;
alter table public.home_cards add column if not exists logo text;
alter table public.home_cards drop constraint if exists home_cards_logo_ok;
alter table public.home_cards add constraint home_cards_logo_ok
  check (logo is null or (logo ~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$' and length(logo) <= 400000));
create index if not exists home_card_requests_ip on public.home_card_requests (ip, created_at);
create index if not exists home_card_requests_agent on public.home_card_requests (agent_id, created_at);

-- save the card (agents save their own). p_logo: leave out to keep the logo, '' to remove it, or a small image. The short link name is picked the first time: first name,
-- then first and last name, then a number, whichever is free.
drop function if exists public.home_card_save(jsonb);
create or replace function public.home_card_save(p_settings jsonb, p_logo text default null)
returns text language plpgsql security definer set search_path = '' as $$
declare me public.profiles%rowtype; s text; base text; full_base text; n int := 1;
begin
  select * into me from public.profiles where id = auth.uid();
  if me.id is null or me.role <> 'agent' or me.status <> 'active' then
    raise exception 'Only active agents can make a home team card.';
  end if;
  if p_settings is null or jsonb_typeof(p_settings) <> 'object' or length(p_settings::text) > 8000 then
    raise exception 'That card is too large to save.';
  end if;
  select slug into s from public.home_cards where agent_id = me.id;
  if s is null then
    full_base := trim(both '-' from regexp_replace(lower(coalesce(me.full_name, '')), '[^a-z0-9]+', '-', 'g'));
    base := split_part(full_base, '-', 1);
    if length(base) < 2 then base := 'agent'; end if;
    if length(full_base) < 2 then full_base := base; end if;
    full_base := left(full_base, 34);
    s := base;
    if exists (select 1 from public.home_cards where slug = s) then s := full_base; end if;
    while exists (select 1 from public.home_cards where slug = s) loop
      n := n + 1; s := full_base || '-' || n;
    end loop;
  end if;
  if p_logo is not null and p_logo <> '' and (p_logo !~ '^data:image/(png|jpeg|webp);base64,' or length(p_logo) > 400000) then
    raise exception 'That logo is too large. Try a PNG or JPG under 250 KB.';
  end if;
  insert into public.home_cards (agent_id, slug, settings, logo) values (me.id, s, p_settings, nullif(p_logo, ''))
  on conflict (agent_id) do update set settings = excluded.settings, updated_at = now(),
    logo = case when p_logo is null then public.home_cards.logo else nullif(p_logo, '') end;
  return s;
end $$;
revoke execute on function public.home_card_save(jsonb, text) from public, anon;
grant execute on function public.home_card_save(jsonb, text) to authenticated;

-- what the request page shows (no login): the agent's name and brokerage, and the services on their card.
-- Vendor names only, never vendor contact details.
create or replace function public.home_card_get(p_slug text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'agent', p.full_name, 'brokerage', p.brokerage, 'phone', p.phone, 'logo', c.logo,
    'priority', coalesce((c.settings ->> 'priority')::boolean, true),
    'featured', coalesce((select jsonb_agg(jsonb_build_object('c', f ->> 'c', 'name', v.name) order by o)
                            from jsonb_array_elements(case when jsonb_typeof(c.settings -> 'featured') = 'array' then c.settings -> 'featured' else '[]'::jsonb end)
                                 with ordinality as x(f, o)
                            left join public.vendors v on v.id::text = (f ->> 'v')
                           where coalesce(f ->> 'c', '') <> ''), '[]'::jsonb),
    'also', case when jsonb_typeof(c.settings -> 'also') = 'array' then c.settings -> 'also' else '[]'::jsonb end)
    from public.home_cards c join public.profiles p on p.id = c.agent_id
   where c.slug = lower(trim(coalesce(p_slug, ''))) and c.active and p.role = 'agent' and p.status = 'active'
$$;
revoke execute on function public.home_card_get(text) from public;
grant execute on function public.home_card_get(text) to anon, authenticated;

-- a client sends a request from the card's page
create or replace function public.home_card_request(p_slug text, p_name text, p_email text, p_phone text, p_address text,
                                                    p_services text[], p_when text, p_notes text, p_company text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  c     public.home_cards%rowtype;
  a     public.profiles%rowtype;
  v_ip  text := public.request_ip();
  nm    text := left(trim(coalesce(p_name, '')), 120);
  em    text := lower(left(trim(coalesce(p_email, '')), 200));
  ph    text := left(trim(coalesce(p_phone, '')), 40);
  addr  text := left(trim(coalesce(p_address, '')), 200);
  svcs  text[];
  picks text := '';
  f     jsonb;
  vname text;
  body  text;
  pid   uuid;
begin
  select * into c from public.home_cards where slug = lower(trim(coalesce(p_slug, ''))) and active;
  if c.agent_id is not null then select * into a from public.profiles where id = c.agent_id; end if;
  if a.id is null or a.role <> 'agent' or a.status <> 'active' then
    raise exception 'This page isn''t active. Reach out to your agent directly.';
  end if;
  -- the hidden "company" box is only ever filled in by bots: say thanks and do nothing
  if coalesce(trim(p_company), '') <> '' then return; end if;
  if nm = '' then raise exception 'Add your name.'; end if;
  if em = '' and ph = '' then raise exception 'Add an email or phone number so we can reach you.'; end if;
  if em <> '' and em !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then raise exception 'Check your email address.'; end if;
  if addr = '' then raise exception 'Add the home''s address.'; end if;
  select array_agg(s order by o) into svcs from (
    select left(trim(x), 40) as s, min(n) as o from unnest(coalesce(p_services, '{}'::text[])) with ordinality as u(x, n)
     where trim(coalesce(x, '')) <> '' group by 1 order by 2 limit 12) q;
  if svcs is null then raise exception 'Pick at least one thing you need.'; end if;
  -- slow down anyone sending lots of requests
  if v_ip is not null and (select count(*) from public.home_card_requests r where r.ip = v_ip and created_at > now() - interval '1 hour') >= 5 then
    raise exception 'You''ve sent a few requests already. Give us a little time to reply, or reach out to your agent directly.';
  end if;
  if (select count(*) from public.home_card_requests where agent_id = a.id and created_at > now() - interval '1 day') >= 30 then
    raise exception 'This page has had a lot of requests today. Please reach out to your agent directly.';
  end if;

  -- which pro is on the card for each service asked for
  for f in select * from jsonb_array_elements(case when jsonb_typeof(c.settings -> 'featured') = 'array' then c.settings -> 'featured' else '[]'::jsonb end) loop
    if (f ->> 'c') = any (svcs) then
      select name into vname from public.vendors where id::text = (f ->> 'v');
      if vname is not null then picks := picks || case when picks = '' then '' else ', ' end || (f ->> 'c') || ': ' || vname; end if;
    end if;
  end loop;

  insert into public.projects (agent_id, agent_name, agent_email, agent_phone, brokerage, address, client_type, categories, notes, source, created_by)
  values (a.id, coalesce(a.full_name, a.email), a.email, a.phone, a.brokerage, addr, 'Buyer', svcs,
          nullif(concat_ws(E'\n',
            'Request from ' || nm || ' through ' || coalesce(split_part(a.full_name, ' ', 1), 'the agent') || '''s home team card.',
            case when coalesce(trim(p_when), '') <> '' then 'Timing: ' || left(trim(p_when), 60) end,
            case when picks <> '' then 'On the card: ' || picks end,
            case when coalesce(trim(p_notes), '') <> '' then 'From the client: ' || left(trim(p_notes), 1500) end), ''),
          'Home team card', nm)
  returning id into pid;
  update public.project_private set client_name = nm, client_email = nullif(em, ''), client_phone = nullif(ph, '') where project_id = pid;
  insert into public.home_card_requests (agent_id, project_id, client_name, client_email, client_phone, ip)
  values (a.id, pid, nm, nullif(em, ''), nullif(ph, ''), v_ip);

  body := public.ep('<b>' || public.h(nm) || '</b> needs <b>' || public.h(lower(array_to_string(svcs, ', '))) || '</b> at <b>' || public.h(addr) || '</b>.')
       || case when coalesce(trim(p_when), '') <> '' then public.ep('Timing: ' || public.h(left(trim(p_when), 60))) else '' end
       || case when picks <> '' then public.ep('On the card: ' || public.h(picks)) else '' end
       || case when coalesce(trim(p_notes), '') <> '' then public.ep('<i>' || public.h(left(trim(p_notes), 600)) || '</i>') else '' end
       || public.ep('Reach them at ' || public.h(concat_ws(' · ', nullif(ph, ''), nullif(em, ''))) || '.');
  perform public.orbyt_email(array[a.email], nm || ' asked for ' || lower(array_to_string(svcs, ', ')) || ' from your home team card',
    'Your client sent a request', body
    || public.ep('It''s in your portal as a project. I''ll set up the intros and quotes, and you''ll see them there as they come in.'),
    'Open the portal', 'card_request_agent');
  perform public.orbyt_email(array[public.admin_email()], 'Home team card request: ' || nm || ' (' || coalesce(a.full_name, a.email) || '''s client)',
    'A home team card request needs matching',
    public.ep('From ' || public.h(coalesce(a.full_name, a.email)) || '''s home team card.') || body,
    'Start matching', 'card_request_admin');
end $$;
revoke execute on function public.home_card_request(text, text, text, text, text, text[], text, text, text) from public;
grant execute on function public.home_card_request(text, text, text, text, text, text[], text, text, text) to anon, authenticated;

-- card requests send their own emails, so skip the general "new project" one for them
create or replace function public.projects_notify() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if public.is_admin() or new.source = 'Home team card' then return new; end if;
  perform public.orbyt_email(array[public.admin_email()], 'New project from ' || new.agent_name || ': ' || new.address, 'A new project needs matching',
    public.ep(public.h(new.agent_name) || ' added <b>' || public.h(new.address) || '</b>' || case when coalesce(new.area, '') <> '' then ' in ' || public.h(new.area) else '' end
              || case when new.target_date is not null then ', target date ' || public.date_text(new.target_date) else '' end || '.')
    || public.ep('Needs: ' || public.h(array_to_string(new.categories, ', ')))
    || case when coalesce(new.notes, '') <> '' then public.ep('Notes: ' || public.h(new.notes)) else '' end,
    'Start matching', 'admin_project');
  return new;
exception when others then
  raise warning 'Orbyt project email skipped: %', sqlerrm;
  return new;
end $$;

-- which services the network covers (no vendor names), so the card maker can say which "also on call" services have a pro yet
create or replace function public.network_services() returns text[] language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(distinct s order by s), '{}') from public.vendors v join public.vendor_admin a on a.vendor_id = v.id, unnest(v.services) s
   where a.approved
$$;
revoke execute on function public.network_services() from public, anon;
grant execute on function public.network_services() to authenticated;

-- ---------- update 14: vendor business overview PDF ----------

alter table public.vendors add column if not exists overview_pdf      text;
alter table public.vendors add column if not exists overview_pdf_name text;

insert into storage.buckets (id, name, public) values ('vendor-public', 'vendor-public', true)
on conflict (id) do update set public = true;

drop policy if exists orbyt_vpublic_write  on storage.objects;
drop policy if exists orbyt_vpublic_remove on storage.objects;
create policy orbyt_vpublic_write on storage.objects for insert to authenticated
  with check (bucket_id = 'vendor-public' and ((storage.foldername(name))[1] = public.my_vendor_id()::text or public.is_admin()));
create policy orbyt_vpublic_remove on storage.objects for delete to authenticated
  using (bucket_id = 'vendor-public' and ((storage.foldername(name))[1] = public.my_vendor_id()::text or public.is_admin()));

-- the private quotes page now includes each vendor's overview PDF
create or replace function public.client_quotes(p_token text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'address', p.address, 'agent', p.agent_name, 'agent_email', p.agent_email, 'agent_phone', p.agent_phone,
    'target_date', p.target_date, 'client_type', p.client_type,
    'services', coalesce((
      select jsonb_agg(jsonb_build_object('service', c, 'quotes', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'bid_id', b.id, 'vendor', coalesce(v.name, b.vendor_name), 'amount', b.amount, 'days', b.days, 'available_from', b.available_from,
                 'note', b.note, 'booked', b.status in ('chosen', 'selected'), 'quote_name', b.quote_name,
                 'overview', v.overview_pdf, 'overview_name', v.overview_pdf_name,
                 'rating', (select round(avg(r.rating)::numeric, 1) from public.reviews r where r.vendor_id = b.vendor_id and r.approved),
                 'review_count', (select count(*) from public.reviews r where r.vendor_id = b.vendor_id and r.approved))
               order by b.submitted_at), '[]'::jsonb)
          from public.bids b left join public.vendors v on v.id = b.vendor_id
         where b.project_id = p.id and b.category = c and b.amount is not null
           and b.status in ('submitted', 'changes', 'chosen', 'selected'))) order by c)
      from unnest(p.categories) as c), '[]'::jsonb))
    from public.client_links l join public.projects p on p.id = l.project_id
   where l.token = p_token and l.revoked_at is null and (l.expires_at is null or l.expires_at > now())
$$;
revoke execute on function public.client_quotes(text) from public;
grant execute on function public.client_quotes(text) to anon, authenticated;

-- ---------- update 15: special offers (stored as featured placement) ----------

alter table public.vendors      add column if not exists promo_offer        text check (promo_offer is null or length(promo_offer) <= 90);
alter table public.vendors      add column if not exists promo_details      text check (promo_details is null or length(promo_details) <= 400);
alter table public.vendors      add column if not exists promo_requested_at timestamptz;
alter table public.vendor_admin add column if not exists featured_until     date;
alter table public.vendor_admin add column if not exists promo_reminded_for date;

-- a vendor asked for featured placement: tell Ashleigh
create or replace function public.vendors_promo_notify() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.promo_requested_at is not null and new.promo_requested_at is distinct from old.promo_requested_at then
    perform public.orbyt_email(array[public.admin_email()], 'Special offer request: ' || new.name,
      new.name || ' wants to run a special offer',
      public.ep(public.h(new.name) || ' asked to run a special offer for Orbyt clients, $20 for 30 days.')
      || case when coalesce(new.promo_offer, '') <> '' then public.ep('Their offer: <b>' || public.h(new.promo_offer) || '</b>'
           || case when coalesce(new.promo_details, '') <> '' then '<br>' || public.h(new.promo_details) else '' end) else '' end
      || public.ep('Send them a $20 payment link at ' || public.h(coalesce(new.email, 'their email')) || '. Once it''s paid, click Mark offer paid on their row in your Vendors tab.'),
      'Open your dashboard', 'admin_promo_request');
  end if;
  return new;
exception when others then
  raise warning 'Orbyt promo email skipped: %', sqlerrm;
  return new;
end $$;
drop trigger if exists vendors_promo_notify on public.vendors;
create trigger vendors_promo_notify after update of promo_requested_at on public.vendors
  for each row execute function public.vendors_promo_notify();
revoke execute on function public.vendors_promo_notify() from public, anon, authenticated;

-- Ashleigh marked it paid (a new or later end date): tell the vendor
create or replace function public.vendor_admin_promo_notify() returns trigger language plpgsql security definer set search_path = '' as $$
declare v public.vendors%rowtype;
begin
  if new.featured and new.featured_until is not null and new.featured_until is distinct from old.featured_until
     and new.featured_until >= current_date then
    select * into v from public.vendors where id = new.vendor_id;
    perform public.orbyt_email(array[public.vendor_email(new.vendor_id)], 'Your Orbyt special offer is live until ' || public.date_text(new.featured_until),
      'Your special offer is live',
      public.ep('Thanks! Your payment is in, and your special offer is live until <b>' || public.date_text(new.featured_until) || '</b>.')
      || public.ep('Agents see it next to your quotes and on your profile, so they can pass the deal on to their clients'
         || case when coalesce(v.promo_offer, '') <> '' then ': <b>' || public.h(v.promo_offer) || '</b>' else '' end || '.')
      || public.ep('You can change your offer anytime from your dashboard.'),
      'Open your dashboard', 'vendor_promo_on');
    update public.vendors set promo_requested_at = null where id = new.vendor_id and promo_requested_at is not null;
  end if;
  return new;
exception when others then
  raise warning 'Orbyt promo email skipped: %', sqlerrm;
  return new;
end $$;
drop trigger if exists vendor_admin_promo_notify on public.vendor_admin;
create trigger vendor_admin_promo_notify after update of featured_until on public.vendor_admin
  for each row execute function public.vendor_admin_promo_notify();
revoke execute on function public.vendor_admin_promo_notify() from public, anon, authenticated;

-- every morning: renewal reminders 5 days out, and switch off promotions that have ended
create or replace function public.promo_run() returns integer language plpgsql security definer set search_path = '' as $$
declare r record; n integer := 0; ended text := '';
begin
  for r in select a.vendor_id, a.featured_until, v.name from public.vendor_admin a join public.vendors v on v.id = a.vendor_id
            where a.featured and a.featured_until = current_date + 5 and a.promo_reminded_for is distinct from a.featured_until loop
    perform public.orbyt_email(array[public.vendor_email(r.vendor_id)], 'Your Orbyt special offer ends ' || public.date_text(r.featured_until),
      'Your special offer ends soon',
      public.ep('Your special offer runs until <b>' || public.date_text(r.featured_until) || '</b>. Want another 30 days? Tap Renew on your dashboard and I''ll send a payment link.'),
      'Open your dashboard', 'vendor_promo_renew');
    update public.vendor_admin set promo_reminded_for = r.featured_until where vendor_id = r.vendor_id;
    n := n + 1;
  end loop;
  for r in select a.vendor_id, v.name from public.vendor_admin a join public.vendors v on v.id = a.vendor_id
            where a.featured and a.featured_until is not null and a.featured_until < current_date loop
    update public.vendor_admin set featured = false where vendor_id = r.vendor_id;
    ended := ended || '<li>' || public.h(r.name) || '</li>';
    n := n + 1;
  end loop;
  if ended <> '' then
    perform public.orbyt_email(array[public.admin_email()], 'Special offers ended', 'Special offers ended',
      public.ep('These special offers ran their 30 days and switched off:')
      || '<ul style="font-size:15px;line-height:1.6;margin:0 0 16px;padding-left:20px">' || ended || '</ul>',
      'Open your dashboard', 'admin_promo_ended');
  end if;
  return n;
end $$;
revoke execute on function public.promo_run() from public, anon, authenticated;

do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('orbyt-promo', '15 16 * * *', 'select public.promo_run()');
exception when others then
  raise warning 'Daily special offer checks were not scheduled (%). In Supabase, turn on the pg_cron extension under Database, Extensions, then run this script again.', sqlerrm;
end $$;
