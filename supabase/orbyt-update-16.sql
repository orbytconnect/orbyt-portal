-- Orbyt update 16: closing partners (lenders, title, escrow, homeowners insurance)
-- 1. Closing partners join through their own sign-up (portal.orbytconnect.com/join/partner) under the
--    Orbyt Closing Partner Terms. Founding members are free. They never pay per introduction or per closing,
--    which keeps Orbyt clear of RESPA's referral fee rules. No bids, job fees, insurance tiers or special offers.
-- 2. Agents ask for closing partners on a project (a separate list from home services). Ashleigh introduces a
--    partner, the partner and the agent each get an email, and the partner marks when they've reached out.
-- 3. Home team cards can show a Closing partners section, and client requests for those go to the new list.
-- Safe to run more than once.

alter table public.vendors  add column if not exists kind           text not null default 'vendor';
alter table public.vendors  drop constraint if exists vendors_kind_ok;
alter table public.vendors  add constraint vendors_kind_ok check (kind in ('vendor', 'closing'));
alter table public.vendors  add column if not exists license_number text;
alter table public.projects add column if not exists closing        text[] not null default '{}';

-- one row per introduction of a closing partner to a project (the details partners need are copied in,
-- since partners can't open the project itself)
create table if not exists public.intros (
  id             uuid primary key default gen_random_uuid(),
  project_id     uuid not null references public.projects (id) on delete cascade,
  category       text not null,
  vendor_id      uuid not null references public.vendors (id) on delete cascade,
  note           text,
  agent_name     text,
  agent_email    text,
  agent_phone    text,
  brokerage      text,
  address        text,
  area           text,
  introduced_at  timestamptz not null default now(),
  reached_out_at timestamptz,
  unique (project_id, category, vendor_id)
);
alter table public.intros enable row level security;
drop policy if exists intros_read on public.intros;
create policy intros_read on public.intros for select to authenticated
  using (public.is_admin() or public.on_project(project_id) or vendor_id = public.my_vendor_id());
drop policy if exists intros_admin on public.intros;
create policy intros_admin on public.intros for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists intros_partner on public.intros;
create policy intros_partner on public.intros for update to authenticated
  using (vendor_id = public.my_vendor_id()) with check (vendor_id = public.my_vendor_id());
revoke all on public.intros from anon;
grant select, insert, update, delete on public.intros to authenticated;

-- partners can only mark that they reached out
create or replace function public.intros_guard() returns trigger language plpgsql security definer set search_path = '' as $$
declare p public.projects%rowtype;
begin
  if tg_op = 'INSERT' then
    select * into p from public.projects where id = new.project_id;
    new.agent_name := p.agent_name; new.agent_email := p.agent_email; new.agent_phone := p.agent_phone;
    new.brokerage := p.brokerage; new.address := p.address; new.area := p.area;
    return new;
  end if;
  if not public.is_admin() and (new.project_id, new.category, new.vendor_id, new.note, new.introduced_at)
       is distinct from (old.project_id, old.category, old.vendor_id, old.note, old.introduced_at) then
    raise exception 'Only Orbyt can change an introduction.';
  end if;
  return new;
end $$;
drop trigger if exists intros_guard on public.intros;
create trigger intros_guard before insert or update on public.intros for each row execute function public.intros_guard();
revoke execute on function public.intros_guard() from public, anon, authenticated;

-- emails for a new introduction: the partner gets the agent's details, the agent gets the partner's
create or replace function public.intros_notify() returns trigger language plpgsql security definer set search_path = '' as $$
declare v public.vendors%rowtype; what text := lower(new.category);
begin
  select * into v from public.vendors where id = new.vendor_id;
  perform public.orbyt_email(array[public.vendor_email(new.vendor_id)],
    'New introduction: ' || coalesce(new.agent_name, 'an agent') || ' needs ' || what || ' help',
    'Meet ' || coalesce(public.first_name(new.agent_name), 'your agent'),
    public.ep('I''d like to introduce you to <b>' || public.h(coalesce(new.agent_name, 'an agent')) || '</b>'
      || case when coalesce(new.brokerage, '') <> '' then ' of ' || public.h(new.brokerage) else '' end
      || '. Their client needs ' || public.h(what) || ' help with <b>' || public.h(coalesce(new.address, 'a home')) || '</b>.')
    || case when coalesce(new.note, '') <> '' then public.ep('<i>' || public.h(new.note) || '</i>') else '' end
    || public.ep('Reach out to ' || public.h(coalesce(public.first_name(new.agent_name), 'them')) || ' at '
      || public.h(concat_ws(' · ', nullif(new.agent_phone, ''), nullif(new.agent_email, ''))) || '. They''ll connect you with their client.')
    || public.ep('Once you''ve been in touch, mark it on your dashboard.'),
    'Open your dashboard', 'partner_intro');
  perform public.orbyt_email(public.project_recipients(new.project_id),
    'Meet your ' || what || ' contact for ' || coalesce(new.address, 'your project') || ': ' || v.name,
    'Your ' || what || ' introduction',
    public.ep('I''ve introduced you to <b>' || public.h(v.name) || '</b>'
      || case when coalesce(v.contact_name, '') <> '' then ' (' || public.h(v.contact_name) || ')' else '' end
      || ' for ' || public.h(what) || ' at <b>' || public.h(coalesce(new.address, 'your project')) || '</b>. They''ll reach out to you.')
    || public.ep('You can reach them at ' || public.h(concat_ws(' · ', nullif(v.phone, ''), nullif(v.email, ''))) || '.')
    || case when coalesce(new.note, '') <> '' then public.ep('<i>' || public.h(new.note) || '</i>') else '' end
    || public.ep('Your client is always free to choose any provider. Orbyt isn''t paid for this introduction.'),
    'See the project', 'agent_intro');
  return new;
exception when others then
  raise warning 'Orbyt intro email skipped: %', sqlerrm;
  return new;
end $$;
drop trigger if exists intros_notify on public.intros;
create trigger intros_notify after insert on public.intros for each row execute function public.intros_notify();
revoke execute on function public.intros_notify() from public, anon, authenticated;

-- an agent adds a closing partner request to an existing project: tell Ashleigh
create or replace function public.projects_closing_notify() returns trigger language plpgsql security definer set search_path = '' as $$
declare added text[];
begin
  if public.is_admin() then return new; end if;
  select coalesce(array_agg(x), '{}') into added from unnest(new.closing) as x where not (x = any (coalesce(old.closing, '{}')));
  if cardinality(added) > 0 then
    perform public.orbyt_email(array[public.admin_email()], new.agent_name || ' asked for ' || lower(array_to_string(added, ', ')) || ': ' || new.address,
      'A closing partner request', public.ep(public.h(new.agent_name) || ' asked for <b>' || public.h(lower(array_to_string(added, ', '))) || '</b> at <b>' || public.h(new.address) || '</b>.'),
      'Introduce someone', 'admin_closing');
  end if;
  return new;
exception when others then
  raise warning 'Orbyt closing email skipped: %', sqlerrm;
  return new;
end $$;
drop trigger if exists projects_closing_notify on public.projects;
create trigger projects_closing_notify after update of closing on public.projects for each row execute function public.projects_closing_notify();
revoke execute on function public.projects_closing_notify() from public, anon, authenticated;

-- agents can see closing partners introduced on their projects
CREATE OR REPLACE FUNCTION public.can_see_vendor(vid uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
as $$
  select public.is_admin()
      or vid = public.my_vendor_id()
      or exists (select 1 from public.bids b where b.vendor_id = vid and public.on_project(b.project_id))
      or exists (select 1 from public.favorites f where f.user_id = auth.uid() and f.vendor_id = vid)
      or exists (select 1 from public.intros i where i.vendor_id = vid and public.on_project(i.project_id))
$$;

-- sign-ups save the closing partner type, license number, and Closing Partner Terms
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
as $$
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
    -- closing partners (lenders, title, escrow, insurance) sign up through their own form
    if m ->> 'partner_kind' = 'closing' then
      update public.vendors set kind = 'closing', license_number = coalesce(nullif(trim(m ->> 'license'), ''), license_number) where id = v_id;
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
  if (m ->> 'terms_version') like r || '-terms-%' or (r = 'vendor' and (m ->> 'terms_version') like 'partner-terms-%') then
    insert into public.terms_acceptances (user_id, email, role, version, source, user_agent, on_behalf_of, signer_title, authority_confirmed)
    values (new.id, em, r, m ->> 'terms_version', 'signup', left(m ->> 'user_agent', 300),
            case when r = 'vendor' then nullif(trim(m ->> 'legal_name'), '') end,
            case when r = 'vendor' then nullif(trim(m ->> 'signer_title'), '') end,
            r = 'vendor' and coalesce((m ->> 'authority')::boolean, false));
  end if;
  return new;
end $$;

-- closing partners agree to the Closing Partner Terms in the portal too
CREATE OR REPLACE FUNCTION public.accept_terms(p_version text, p_user_agent text DEFAULT NULL::text, p_details jsonb DEFAULT NULL::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
as $$
declare r text; em text; new_id uuid; vid uuid; d jsonb := coalesce(p_details, '{}'::jsonb); ln text;
begin
  select role, lower(email) into r, em from public.profiles where id = auth.uid();
  if r is null or r not in ('agent', 'vendor') then raise exception 'Only agents and vendors accept these terms'; end if;
  if p_version is null or (p_version not like r || '-terms-%' and not (r = 'vendor' and p_version like 'partner-terms-%')) then raise exception 'Those terms are not for this account'; end if;
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

-- the approval email for closing partners skips fees and insurance
CREATE OR REPLACE FUNCTION public.profiles_notify()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
as $$
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
    if new.role = 'vendor' and exists (select 1 from public.vendors where user_id = new.id and kind = 'closing') then
      perform public.orbyt_email(array[new.email], 'You''re approved as an Orbyt closing partner', 'You''re in, ' || public.first_name(new.full_name),
        public.ep('Thanks for your patience while I checked everything. You''re approved as a founding Orbyt closing partner, free of charge.')
        || public.ep('When an agent in the network asks for help you provide, I may introduce you. You''ll get an email with their details, and the introduction shows on your dashboard.'),
        'Sign in to Orbyt', 'approved');
    elsif new.role = 'vendor' then
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

-- insurance certificate reminders are for home service vendors only
CREATE OR REPLACE FUNCTION public.insurance_reminders_run()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
as $$
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
      join public.vendor_admin a on a.vendor_id = v.id and a.approved and v.kind <> 'closing'
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

-- new project emails list closing partner requests too
CREATE OR REPLACE FUNCTION public.projects_notify()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
as $$
begin
  if public.is_admin() or new.source = 'Home team card' then return new; end if;
  perform public.orbyt_email(array[public.admin_email()], 'New project from ' || new.agent_name || ': ' || new.address, 'A new project needs matching',
    public.ep(public.h(new.agent_name) || ' added <b>' || public.h(new.address) || '</b>' || case when coalesce(new.area, '') <> '' then ' in ' || public.h(new.area) else '' end
              || case when new.target_date is not null then ', target date ' || public.date_text(new.target_date) else '' end || '.')
    || public.ep('Needs: ' || public.h(array_to_string(new.categories || coalesce(new.closing, '{}'), ', ')))
    || case when coalesce(new.notes, '') <> '' then public.ep('Notes: ' || public.h(new.notes)) else '' end,
    'Start matching', 'admin_project');
  return new;
exception when others then
  raise warning 'Orbyt project email skipped: %', sqlerrm;
  return new;
end $$;

-- the card's request page lists the closing partners too
CREATE OR REPLACE FUNCTION public.home_card_get(p_slug text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
as $$
  select jsonb_build_object(
    'agent', p.full_name, 'brokerage', p.brokerage, 'phone', p.phone, 'logo', c.logo,
    'priority', coalesce((c.settings ->> 'priority')::boolean, true),
    'featured', coalesce((select jsonb_agg(jsonb_build_object('c', f ->> 'c', 'name', v.name) order by o)
                            from jsonb_array_elements(case when jsonb_typeof(c.settings -> 'featured') = 'array' then c.settings -> 'featured' else '[]'::jsonb end)
                                 with ordinality as x(f, o)
                            left join public.vendors v on v.id::text = (f ->> 'v')
                           where coalesce(f ->> 'c', '') <> ''), '[]'::jsonb),
    'closing', coalesce((select jsonb_agg(jsonb_build_object('c', f ->> 'c', 'name', v.name) order by o)
                            from jsonb_array_elements(case when jsonb_typeof(c.settings -> 'closing') = 'array' then c.settings -> 'closing' else '[]'::jsonb end)
                                 with ordinality as x(f, o)
                            left join public.vendors v on v.id::text = (f ->> 'v')
                           where coalesce(f ->> 'c', '') <> ''), '[]'::jsonb),
    'also', case when jsonb_typeof(c.settings -> 'also') = 'array' then c.settings -> 'also' else '[]'::jsonb end)
    from public.home_cards c join public.profiles p on p.id = c.agent_id
   where c.slug = lower(trim(coalesce(p_slug, ''))) and c.active and p.role = 'agent' and p.status = 'active'
$$;

-- client requests for closing partners go to the project's closing list
CREATE OR REPLACE FUNCTION public.home_card_request(p_slug text, p_name text, p_email text, p_phone text, p_address text, p_services text[], p_when text, p_notes text, p_company text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
as $$
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
  for f in select * from jsonb_array_elements((case when jsonb_typeof(c.settings -> 'featured') = 'array' then c.settings -> 'featured' else '[]'::jsonb end)
                            || (case when jsonb_typeof(c.settings -> 'closing') = 'array' then c.settings -> 'closing' else '[]'::jsonb end)) loop
    if (f ->> 'c') = any (svcs) then
      select name into vname from public.vendors where id::text = (f ->> 'v');
      if vname is not null then picks := picks || case when picks = '' then '' else ', ' end || (f ->> 'c') || ': ' || vname; end if;
    end if;
  end loop;

  insert into public.projects (agent_id, agent_name, agent_email, agent_phone, brokerage, address, client_type, categories, closing, notes, source, created_by)
  values (a.id, coalesce(a.full_name, a.email), a.email, a.phone, a.brokerage, addr, 'Buyer',
          coalesce((select array_agg(x order by o) from unnest(svcs) with ordinality as u(x, o) where not (x = any (array['Lender', 'Title', 'Escrow', 'Homeowners insurance']))), '{}'),
          coalesce((select array_agg(x order by o) from unnest(svcs) with ordinality as u(x, o) where x = any (array['Lender', 'Title', 'Escrow', 'Homeowners insurance'])), '{}'),
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
