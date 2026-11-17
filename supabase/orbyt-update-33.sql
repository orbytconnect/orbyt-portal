-- Orbyt update 33: batch 3
-- 1. Structured reviews: agents rate quality of work, on time, communication and value for the price,
--    and say whether they'd hire the vendor again. Profiles show the averages once there are 3 or more.
-- 2. Special offers can be tied to some of a vendor's services.
-- 3. The 3-level service list: vendors and closing partners save the specific services they offer.
-- Needs update 32 first. Safe to run more than once.

alter table public.reviews add column if not exists scores jsonb;
alter table public.reviews add column if not exists book_again boolean;
alter table public.vendors add column if not exists promo_services text[];
alter table public.vendors add column if not exists service_details text[] not null default '{}';

-- only the four areas, each a whole number from 1 to 5
create or replace function public.review_scores_clean(p jsonb) returns jsonb
language sql immutable set search_path = '' as $$
  select nullif(coalesce(jsonb_object_agg(k, (p ->> k)::int) filter (where (p ->> k) ~ '^[1-5]$'), '{}'::jsonb), '{}'::jsonb)
  from unnest(array['quality', 'timeliness', 'communication', 'value']) k
$$;
create or replace function public.reviews_scores_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.scores := public.review_scores_clean(new.scores);
  return new;
end $$;
drop trigger if exists reviews_scores_guard on public.reviews;
create trigger reviews_scores_guard before insert or update of scores on public.reviews
  for each row execute function public.reviews_scores_guard();

drop function if exists public.review_request_submit(text, integer, text, text, text, text);
CREATE OR REPLACE FUNCTION public.review_request_submit(p_token text, p_rating integer, p_comment text, p_name text, p_brokerage text, p_when text, p_scores jsonb DEFAULT NULL::jsonb, p_again boolean DEFAULT NULL::boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare q public.review_requests%rowtype; v public.vendors%rowtype; rid uuid;
begin
  select * into q from public.review_requests where token = p_token and length(coalesce(p_token, '')) >= 32 for update;
  if q.id is null then raise exception 'This review link isn''t active.'; end if;
  if q.completed_at is not null then raise exception 'This review has already been sent. Thank you!'; end if;
  if p_rating is null or p_rating not between 1 and 5 then raise exception 'Pick a star rating from 1 to 5.'; end if;
  if coalesce(trim(p_comment), '') = '' then raise exception 'Add a few words about the work.'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Add your name.'; end if;
  if coalesce(trim(p_brokerage), '') = '' then raise exception 'Add your brokerage.'; end if;
  insert into public.reviews (vendor_id, agent_name, rating, comment, approved, source, reviewer_email, reviewer_brokerage, work_when, scores, book_again)
  values (q.vendor_id, left(trim(p_name), 120), p_rating, left(trim(p_comment), 2000), false, 'past_client',
          q.agent_email, left(trim(p_brokerage), 160), nullif(left(trim(coalesce(p_when, '')), 40), ''), public.review_scores_clean(p_scores), p_again)
  returning id into rid;
  update public.review_requests set completed_at = now(), review_id = rid, submit_ip = public.request_ip() where id = q.id;
  select * into v from public.vendors where id = q.vendor_id;
  perform public.orbyt_email(array[public.admin_email()],
    'New review to approve: ' || v.name, 'A past client reviewed ' || v.name,
    public.ep('<b>' || public.h(trim(p_name)) || '</b> (' || public.h(trim(p_brokerage)) || ', ' || public.h(q.agent_email) || ') gave '
      || public.h(v.name) || ' ' || p_rating || case when p_rating = 1 then ' star' else ' stars' end
      || case when p_again is not null then case when p_again then ', and would hire them again' else ', and would not hire them again' end else '' end
      || case when coalesce(trim(p_when), '') <> '' then ' for work in ' || public.h(trim(p_when)) else '' end || '.')
    || public.ep('<i>' || public.h(left(trim(p_comment), 600)) || '</i>')
    || public.ep('Check that it''s a real agent, then approve it from your dashboard. Honest critical reviews get approved too.'),
    'Review it', 'admin_review');
end $function$;
grant execute on function public.review_request_submit(text, integer, text, text, text, text, jsonb, boolean) to anon, authenticated;

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

-- let the API see the new columns right away
notify pgrst, 'reload schema';
