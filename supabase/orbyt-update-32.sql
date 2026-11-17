-- Orbyt update 32: vendors and closing partners get their dashboard right away
-- 1. New vendors and closing partners can sign in to their dashboard as soon as they confirm their email.
--    Ashleigh still approves them (after checking references, license and insurance) before any introductions or listing.
-- 2. Anyone waiting on approval today gets their dashboard now. Nothing changes for agents.
-- 3. The "You're approved" and "Your listing is live" emails now go out when Ashleigh approves them.
-- 4. Vendors whose services need insurance before their first introduction see it in their setup list and reminders.
-- Needs updates 29 to 31 first. Safe to run more than once.

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
    if new.status = 'pending' or (new.role = 'vendor' and not exists (
         select 1 from public.vendors v join public.vendor_admin a on a.vendor_id = v.id where lower(v.email) = lower(new.email) and a.approved)) then
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

CREATE OR REPLACE FUNCTION public.vendor_setup_missing(p_vendor uuid)
 RETURNS text[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select case when v.kind = 'closing' then array_remove(array[
    case when length(trim(coalesce(v.license_number, ''))) < 3 then 'license number' end,
    case when coalesce(v.years_in_business, '') = '' then 'years in business' end,
    case when coalesce((select (value ->> 'enabled')::boolean from public.settings where key = 'billing'), false)
          and not exists (select 1 from public.vendor_billing b where b.vendor_id = v.id and b.stripe_subscription_id is not null and coalesce(b.billing_status, '') <> 'canceled')
         then 'card on file' end], null)
  else array_remove(array[
    case when coalesce(v.years_in_business, '') = '' then 'years in business' end,
    case when coalesce(v.team_size, '') = '' then 'team size' end,
    case when coalesce(v.lead_time, '') = '' then 'typical lead time' end,
    case when length(trim(coalesce(p.references_text, ''))) < 10 then 'agent references' end,
    case when public.insurance_group(v.services) = 'high' and coalesce(p.insurance ->> 'path', '') = '' then 'certificate of insurance' end], null) end
  from public.vendors v left join public.vendor_private p on p.vendor_id = v.id
  where v.id = p_vendor
$function$;

CREATE OR REPLACE FUNCTION public.vendor_setup_send(p_vendor uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.vendors%rowtype; miss text[]; confirmed boolean; first text; body text; n integer; cp boolean;
begin
  select * into v from public.vendors where id = p_vendor;
  if v.id is null or v.user_id is null then return false; end if;
  miss := public.vendor_setup_missing(p_vendor);
  if coalesce(array_length(miss, 1), 0) = 0 then return false; end if;
  cp := coalesce(v.kind, '') = 'closing';
  select email_confirmed_at is not null into confirmed from auth.users where id = v.user_id;
  select coalesce(setup_reminders, 0) into n from public.vendor_admin where vendor_id = v.id;
  first := split_part(coalesce(nullif(v.contact_name, ''), ''), ' ', 1);
  body := '<p style="font-size:15px;line-height:1.6;margin:0 0 12px">Hi' || case when first <> '' then ' ' || public.h(first) else '' end || ',</p>'
       || '<p style="font-size:15px;line-height:1.6;margin:0 0 12px">Thanks for starting your Orbyt sign-up for ' || public.h(v.name)
       || case when cp then '. Before I can check your license and publish your listing in the closing partner directory, I need a few more details:</p>'
               else '. Your dashboard is open, and before I can approve you and start introducing you to agents, I need a few more details:</p>' end
       || '<ul style="font-size:15px;line-height:1.6;margin:0 0 12px;padding-left:20px">'
       || (select string_agg('<li>' || public.h(upper(left(m, 1)) || substr(m, 2))
                  || case when m = 'card on file' then ' (nothing is charged during your 90-day launch offer)' else '' end || '</li>', '') from unnest(miss) m)
       || '</ul><p style="font-size:15px;line-height:1.6;margin:0 0 12px">It takes a few minutes. Sign in and you''ll find it all under Get approved at the top of your dashboard.</p>'
       || case when not coalesce(confirmed, false) then
            '<p style="font-size:15px;line-height:1.6;margin:0 0 12px">First, confirm your email with the link I sent when you signed up. Can''t find it? Just reply and I''ll help.</p>' else '' end;
  perform public.orbyt_email_link(array[v.email],
    case when cp then case when n = 0 then 'Finish your Orbyt listing' else 'Still want to be listed? Finish your Orbyt listing' end
         else case when n = 0 then 'Finish your Orbyt profile' else 'Still want agent introductions? Finish your Orbyt profile' end end,
    'Almost approved', body, case when cp then 'Finish my listing' else 'Finish my profile' end, 'vendor_setup_reminder', null);
  update public.vendor_admin set setup_reminders = coalesce(setup_reminders, 0) + 1, setup_reminded_at = now() where vendor_id = v.id;
  return true;
end $function$;

create or replace function public.vendor_admin_approved_notify() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v public.vendors%rowtype; first text;
begin
  if not (new.approved and not coalesce(old.approved, false)) then return new; end if;
  select * into v from public.vendors where id = new.vendor_id;
  if v.id is null or v.user_id is null or coalesce(v.email, '') = '' then return new; end if;
  first := public.first_name(coalesce(nullif(v.contact_name, ''), (select full_name from public.profiles where id = v.user_id)));
  if coalesce(v.kind, '') = 'closing' then
    perform public.orbyt_email(array[v.email], 'Your Orbyt closing partner listing is live', 'You''re listed, ' || first,
      public.ep('Thanks for your patience while I checked your license. Your listing is now live in the Orbyt closing partner directory, where agents in the network can find you and your business overview.')
      || public.ep('Your first 90 days are free. After that, your marketing listing is $20 a month, and you can cancel anytime.'),
      'Sign in to Orbyt', 'approved');
  else
    perform public.orbyt_email(array[v.email], 'You''re approved for the Orbyt network', 'You''re in, ' || first,
      public.ep('Thanks for your patience while I checked everything. You''re approved as an Orbyt vendor partner, so I can start introducing you to agents.')
      || public.ep('When you sign in, you''ll see exactly what Orbyt costs (you only pay when an introduction turns into a paid job) and the insurance paperwork your services need.'),
      'Sign in to Orbyt', 'approved');
  end if;
  return new;
exception when others then
  raise warning 'Orbyt approval email skipped: %', sqlerrm;
  return new;
end $$;
revoke execute on function public.vendor_admin_approved_notify() from public, anon, authenticated;
drop trigger if exists vendor_admin_approved_notify on public.vendor_admin;
create trigger vendor_admin_approved_notify after update of approved on public.vendor_admin
  for each row execute function public.vendor_admin_approved_notify();

-- everyone waiting on approval today gets their dashboard (they stay unapproved for introductions)
update public.profiles set status = 'active' where role = 'vendor' and status = 'pending';
