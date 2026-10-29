-- Orbyt update 12: portfolios, home details, and referrals
-- 1. Vendors can add an Instagram handle and a portfolio PDF, alongside their website and portfolio link.
-- 2. Projects can record the home's square footage, and the expected list price for listings
--    (the list price is private to the agent, people they share with, and Ashleigh).
-- 3. Sign-up links shared from the portal carry a referral code, so Ashleigh sees who referred each new agent or vendor.
-- Safe to run more than once.

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
