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
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  m        jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  r        text  := case when m ->> 'role' = 'vendor' then 'vendor' else 'agent' end;
  em       text  := lower(new.email);
  invited  boolean;
  v_id     uuid;
begin
  invited := r = 'agent' and (
    exists (select 1 from public.project_members where lower(email) = em)
    or exists (select 1 from public.default_shares where lower(email) = em));

  insert into public.profiles (id, role, status, full_name, email, phone, brokerage, areas, approved_at)
  values (new.id, r, case when invited then 'active' else 'pending' end,
          nullif(trim(m ->> 'full_name'), ''), em, m ->> 'phone', m ->> 'brokerage',
          public.jsonb_text_array(m -> 'areas'), case when invited then now() end)
  on conflict (id) do nothing;

  update public.project_members set user_id = new.id where user_id is null and lower(email) = em;

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
  if auth.uid() is null or pg_trigger_depth() > 1 or public.is_admin() then return new; end if;
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
  'portal_url', 'https://orbyt-portal.netlify.app',
  'from', 'Orbyt <ashleigh@orbytconnect.com>',
  'admin', 'ashleigh@orbytconnect.com',
  'logo', 'https://orbyt-portal.netlify.app/orbyt-logo-email.png'), false)
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
        || public.ep('When you sign in, you''ll see exactly what Orbyt costs (you only pay when an introduction turns into a paid job) and the vendor agreement to sign. Then you''re ready for your first introduction.'),
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
