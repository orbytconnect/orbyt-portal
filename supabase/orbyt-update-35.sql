-- Orbyt update 35: vendor team members
-- 1. A vendor can invite people on their team. Each gets their own login to help with quotes, messages and jobs.
--    Team members can't change the profile, billing, insurance or references, and don't see Orbyt fees.
-- 2. A vendor (or a team member) can tag who's handling a request or job, and that person gets an email.
-- Needs update 34 first. Safe to run more than once.

create table if not exists public.vendor_members (
  id          uuid primary key default gen_random_uuid(),
  vendor_id   uuid not null references public.vendors(id) on delete cascade,
  email       text not null,
  name        text,
  user_id     uuid references auth.users(id) on delete set null,
  token       text not null unique default (replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')),
  invited_by  uuid,
  invited_at  timestamptz not null default now(),
  accepted_at timestamptz,
  removed_at  timestamptz
);
create unique index if not exists vendor_members_one on public.vendor_members (vendor_id, lower(email)) where removed_at is null;
create index if not exists vendor_members_user on public.vendor_members (user_id) where removed_at is null;
alter table public.vendor_members enable row level security;
alter table public.bids add column if not exists assigned_to uuid references auth.users(id) on delete set null;

-- the vendor this person works for: their own business, or the team they were invited to
create or replace function public.my_vendor_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select id from public.vendors where user_id = auth.uid() limit 1),
    (select m.vendor_id from public.vendor_members m where m.user_id = auth.uid() and m.removed_at is null order by m.accepted_at limit 1))
$$;
-- only the owner of the vendor account
create or replace function public.my_owned_vendor_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select id from public.vendors where user_id = auth.uid() limit 1
$$;
grant execute on function public.my_vendor_id() to authenticated;
grant execute on function public.my_owned_vendor_id() to authenticated;

drop policy if exists vendor_members_read on public.vendor_members;
create policy vendor_members_read on public.vendor_members for select
  using (public.is_admin() or vendor_id = public.my_vendor_id());

-- the owner keeps the business side to themselves
drop policy if exists vendor_private_read on public.vendor_private;
create policy vendor_private_read on public.vendor_private for select using (vendor_id = public.my_owned_vendor_id() or public.is_admin());
drop policy if exists vendor_private_edit on public.vendor_private;
create policy vendor_private_edit on public.vendor_private for update
  using (vendor_id = public.my_owned_vendor_id() or public.is_admin()) with check (vendor_id = public.my_owned_vendor_id() or public.is_admin());
drop policy if exists vendor_agreements_sign on public.vendor_agreements;
create policy vendor_agreements_sign on public.vendor_agreements for insert with check (vendor_id = public.my_owned_vendor_id() and public.is_active());
drop policy if exists vendor_billing_read on public.vendor_billing;
create policy vendor_billing_read on public.vendor_billing for select using (vendor_id = public.my_owned_vendor_id() or public.is_admin());
drop policy if exists listing_payments_own on public.listing_payments;
create policy listing_payments_own on public.listing_payments for select using (vendor_id = public.my_owned_vendor_id());
drop policy if exists invoices_read on public.invoices;
create policy invoices_read on public.invoices for select
  using (public.is_admin() or exists (select 1 from public.bids b where b.id = invoices.bid_id and b.vendor_id = public.my_owned_vendor_id()));

-- the team, for the owner's Profile tab and the "Handled by" picker
create or replace function public.vendor_team() returns table (user_id uuid, member_id uuid, name text, email text, owner boolean, joined boolean, invited_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select v.user_id, null::uuid, coalesce(nullif(v.contact_name, ''), p.full_name, v.email), coalesce(p.email, v.email), true, true, null::timestamptz
    from public.vendors v left join public.profiles p on p.id = v.user_id
   where v.id = public.my_vendor_id() and v.user_id is not null
  union all
  select m.user_id, m.id, coalesce(nullif(m.name, ''), m.email), m.email, false, m.user_id is not null, m.invited_at
    from public.vendor_members m where m.vendor_id = public.my_vendor_id() and m.removed_at is null
$$;
grant execute on function public.vendor_team() to authenticated;

create or replace function public.vendor_member_send(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare m public.vendor_members%rowtype; v public.vendors%rowtype; url text; boss text;
begin
  select * into m from public.vendor_members where id = p_id;
  select * into v from public.vendors where id = m.vendor_id;
  url := coalesce((select value ->> 'portal_url' from public.settings where key = 'email'), 'https://portal.orbytconnect.com') || '/?team=' || m.token;
  boss := coalesce(nullif(v.contact_name, ''), v.name);
  perform public.orbyt_email_link(array[m.email], boss || ' added you to the ' || v.name || ' team on Orbyt',
    'Join ' || v.name || ' on Orbyt',
    public.ep(public.h(boss) || ' added you to the ' || public.h(v.name) || ' team on Orbyt, where real estate agents send bid requests for their listings.')
    || public.ep('With your own login, you can send quotes, message agents and keep jobs moving. It takes about a minute to set up.'),
    'Set up my login', 'team_invite', url);
end $$;
revoke execute on function public.vendor_member_send(uuid) from public, anon, authenticated;

create or replace function public.vendor_member_invite(p_name text, p_email text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare vid uuid := public.my_owned_vendor_id(); em text := lower(trim(coalesce(p_email, ''))); mid uuid;
begin
  if vid is null then raise exception 'Only the account owner can invite team members.'; end if;
  if em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email.'; end if;
  if em = lower(coalesce((select email from public.profiles where id = auth.uid()), '')) then raise exception 'That''s your own email.'; end if;
  if (select count(*) from public.vendor_members where vendor_id = vid and removed_at is null) >= 25 then raise exception 'You can have up to 25 team members.'; end if;
  select id into mid from public.vendor_members where vendor_id = vid and lower(email) = em and removed_at is null;
  if mid is not null then raise exception 'They''re already on your team.'; end if;
  insert into public.vendor_members (vendor_id, email, name, invited_by) values (vid, em, nullif(left(trim(coalesce(p_name, '')), 80), ''), auth.uid())
  returning id into mid;
  -- someone who already has an Orbyt login joins right away
  update public.vendor_members m set user_id = p.id, accepted_at = now()
    from public.profiles p where m.id = mid and lower(p.email) = em and p.role = 'vendor'
     and not exists (select 1 from public.vendors x where x.user_id = p.id);
  perform public.vendor_member_send(mid);
  return mid;
end $$;
grant execute on function public.vendor_member_invite(text, text) to authenticated;

create or replace function public.vendor_member_resend(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.vendor_members where id = p_id and vendor_id = public.my_owned_vendor_id() and removed_at is null) then
    raise exception 'Only the account owner can do that.'; end if;
  perform public.vendor_member_send(p_id);
end $$;
grant execute on function public.vendor_member_resend(uuid) to authenticated;

create or replace function public.vendor_member_remove(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare u uuid;
begin
  update public.vendor_members set removed_at = now() where id = p_id and vendor_id = public.my_owned_vendor_id() and removed_at is null
  returning user_id into u;
  if not found then raise exception 'Only the account owner can do that.'; end if;
  if u is not null then update public.bids set assigned_to = null where assigned_to = u; end if;
end $$;
grant execute on function public.vendor_member_remove(uuid) to authenticated;

-- the join page: who invited them
create or replace function public.team_invite_info(p_token text) returns table (vendor_name text, email text, name text, used boolean)
language sql stable security definer set search_path = '' as $$
  select v.name, m.email, m.name, m.user_id is not null
    from public.vendor_members m join public.vendors v on v.id = m.vendor_id
   where m.token = p_token and m.removed_at is null
$$;
grant execute on function public.team_invite_info(text) to anon, authenticated;

-- someone already signed in (with the invited email) accepts
create or replace function public.team_accept(p_token text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare m public.vendor_members%rowtype;
begin
  select * into m from public.vendor_members where token = p_token and removed_at is null;
  if m.id is null then raise exception 'That invite is no longer active. Ask for a new one.'; end if;
  if lower(m.email) <> lower(coalesce((select email from public.profiles where id = auth.uid()), '')) then
    raise exception 'This invite was sent to %. Sign in with that email to accept it.', m.email; end if;
  if exists (select 1 from public.vendors where user_id = auth.uid()) then raise exception 'You already have your own vendor account on Orbyt.'; end if;
  update public.vendor_members set user_id = auth.uid(), accepted_at = coalesce(accepted_at, now()) where id = m.id;
  update public.profiles set role = 'vendor', status = 'active' where id = auth.uid() and role <> 'orbyt';
  return m.vendor_id;
end $$;
grant execute on function public.team_accept(text) to authenticated;

-- tag who's handling a request or job; they get an email
create or replace function public.bid_assign(p_bid uuid, p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare b public.bids%rowtype; p public.projects%rowtype; v public.vendors%rowtype; em text; who text;
begin
  select * into b from public.bids where id = p_bid;
  if b.id is null or b.vendor_id is distinct from public.my_vendor_id() then raise exception 'That isn''t one of your requests.'; end if;
  select * into v from public.vendors where id = b.vendor_id;
  if p_user is not null and p_user is distinct from v.user_id
     and not exists (select 1 from public.vendor_members where vendor_id = v.id and user_id = p_user and removed_at is null) then
    raise exception 'They aren''t on your team.'; end if;
  update public.bids set assigned_to = p_user where id = p_bid;
  if p_user is not null and p_user <> auth.uid() then
    select * into p from public.projects where id = b.project_id;
    select email into em from public.profiles where id = p_user;
    who := coalesce((select full_name from public.profiles where id = auth.uid()), 'Your team');
    if em is not null then
      perform public.orbyt_email(array[em], who || ' tagged you on ' || b.category || ' for ' || p.address,
        'You''re handling this one', public.ep(public.h(who) || ' tagged you on the <b>' || public.h(lower(b.category)) || '</b> request for <b>' || public.h(p.address) || '</b>. Sign in to see the details, send the quote or message the agent.'),
        'Open it in Orbyt', 'assigned');
      perform public.orbyt_push(array[em], 'You''re handling this one', b.category || ' for ' || p.address, 'assigned');
    end if;
  end if;
end $$;
grant execute on function public.bid_assign(uuid, uuid) to authenticated;

CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  m        jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  r        text  := case when m ->> 'role' = 'vendor' then 'vendor' else 'agent' end;
  em       text  := lower(new.email);
  invited  boolean;
  v_id     uuid;
  tm       public.vendor_members%rowtype;
begin
  -- a team member joining from their invite link: an account on the vendor's team, not a new vendor
  if coalesce(m ->> 'team_token', '') <> '' then
    select * into tm from public.vendor_members
     where token = m ->> 'team_token' and lower(email) = lower(new.email) and removed_at is null and user_id is null;
    if tm.id is not null then
      insert into public.profiles (id, role, status, full_name, email, phone, approved_at)
      values (new.id, 'vendor', 'active', coalesce(nullif(trim(m ->> 'full_name'), ''), tm.name), lower(new.email), m ->> 'phone', now())
      on conflict (id) do nothing;
      update public.vendor_members set user_id = new.id, accepted_at = now(),
             name = coalesce(nullif(trim(m ->> 'full_name'), ''), name) where id = tm.id;
      if (m ->> 'terms_version') like 'vendor-terms-%' then
        insert into public.terms_acceptances (user_id, email, role, version, source, user_agent, authority_confirmed)
        values (new.id, lower(new.email), 'vendor', m ->> 'terms_version', 'signup', left(m ->> 'user_agent', 300), false);
      end if;
      return new;
    end if;
  end if;
  -- agents who are already on a project (shared with them, or imported/added by Orbyt under their email)
  -- and vendors Orbyt already approved skip the approval wait
  invited := (r = 'agent' and (
    exists (select 1 from public.project_members where lower(email) = em)
    or exists (select 1 from public.default_shares where lower(email) = em)
    or exists (select 1 from public.projects where agent_id is null and lower(agent_email) = em)))
    or (r = 'vendor' and exists (select 1 from public.vendors v join public.vendor_admin a on a.vendor_id = v.id
                                 where v.user_id is null and lower(v.email) = em and a.approved));

  insert into public.profiles (id, role, status, full_name, email, phone, brokerage, areas, approved_at)
  values (new.id, r, case when invited or r = 'vendor' then 'active' else 'pending' end,
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
                                  years_in_business, team_size, lead_time, works_with_agents, portfolio_url, instagram, source, service_details)
      values (new.id, coalesce(nullif(trim(m ->> 'company'), ''), nullif(trim(m ->> 'full_name'), ''), em),
              m ->> 'full_name', em, m ->> 'phone', m ->> 'website',
              public.jsonb_text_array(m -> 'services'), public.jsonb_text_array(m -> 'areas'),
              m ->> 'years_in_business', m ->> 'team_size', m ->> 'lead_time',
              m ->> 'works_with_agents', nullif(trim(m ->> 'portfolio_url'), ''), nullif(trim(m ->> 'instagram'), ''), 'Portal sign-up',
              public.jsonb_text_array(m -> 'service_details'))
      returning id into v_id;
      insert into public.vendor_admin (vendor_id) values (v_id) on conflict do nothing;
    else
      update public.vendors set user_id = new.id,
             website       = coalesce(website, nullif(trim(m ->> 'website'), '')),
             portfolio_url = coalesce(portfolio_url, nullif(trim(m ->> 'portfolio_url'), '')),
             instagram     = coalesce(instagram, nullif(trim(m ->> 'instagram'), '')),
             service_details = case when cardinality(service_details) > 0 then service_details else public.jsonb_text_array(m -> 'service_details') end
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
end $function$;

CREATE OR REPLACE FUNCTION public.profiles_notify()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  meta jsonb;
  who  text;
  lbl  text;
begin
  if tg_op = 'INSERT' then
    -- vendors and closing partners start active (they see their dashboard right away), so Ashleigh still hears about them
    if (new.status = 'pending' or (new.role = 'vendor' and not exists (
         select 1 from public.vendors v join public.vendor_admin a on a.vendor_id = v.id where lower(v.email) = lower(new.email) and a.approved)))
       -- a vendor's team member joining from their invite isn't a new vendor
       and not exists (select 1 from public.vendor_members mm where mm.user_id = new.id) then
      select raw_user_meta_data into meta from auth.users where id = new.id;
      who := coalesce(nullif(trim(meta ->> 'company'), ''), new.full_name, new.email);
      lbl := case when new.role = 'vendor' and meta ->> 'partner_kind' = 'closing' then 'closing partner' else new.role end;
      perform public.orbyt_email(array[public.admin_email()],
        'New ' || lbl || ' sign-up: ' || who, 'New ' || lbl || ' sign-up',
        public.ep('<b>' || public.h(who) || '</b>' || case when new.role = 'vendor' and coalesce(meta ->> 'full_name', '') <> '' then ' (' || public.h(meta ->> 'full_name') || ')' else '' end
                  || ' just joined as ' || case when lbl = 'closing partner' then 'a closing partner' when new.role = 'vendor' then 'a vendor partner' else 'an agent' end || '. ' || public.h(new.email)
                  || case when coalesce(new.phone, '') <> '' then ', ' || public.h(new.phone) else '' end || '.')
        || case when coalesce(meta ->> 'services', '') <> '' then public.ep('Services: ' || public.h(array_to_string(public.jsonb_text_array(meta -> 'services'), ', '))) else '' end
        || case when cardinality(new.areas) > 0 then public.ep('Areas: ' || public.h(array_to_string(new.areas, ', '))) else '' end
        || case when lbl = 'closing partner' and coalesce(meta ->> 'license', '') <> '' then public.ep('License: ' || public.h(meta ->> 'license')) else '' end
        || case when coalesce(new.brokerage, '') <> '' then public.ep('Brokerage: ' || public.h(new.brokerage)) else '' end,
        'Review in Orbyt', 'admin_signup');
    end if;
    return new;
  end if;
  if new.status = 'active' and old.status = 'pending' then
    if new.role = 'vendor' then
      null;  -- sent by vendor_admin_approved_notify when Ashleigh approves them
    elsif new.role = 'vendor' and exists (select 1 from public.vendors where user_id = new.id and kind = 'closing') then
      perform public.orbyt_email(array[new.email], 'Your Orbyt closing partner listing is live', 'You''re listed, ' || public.first_name(new.full_name),
        public.ep('Thanks for your patience while I checked your license. Your listing is now live in the Orbyt closing partner directory, where agents in the network can find you and your business overview.')
        || public.ep('Your first 90 days are free. After that, your marketing listing is $20 a month, and you can cancel anytime.'),
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
end $function$;

notify pgrst, 'reload schema';
