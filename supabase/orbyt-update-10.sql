-- Orbyt update 10: vendor Review & Agree details, and review requests to past clients
-- 1. Vendor sign-up now records the legal business name, DBA, business type, the signer's title,
--    that they have authority to agree for the business, and whether they opted out of Orbyt updates.
-- 2. Approved vendors can invite up to 10 agents they've worked with to leave a review.
--    Each agent gets a private link (no login). Reviews wait for Ashleigh's approval and show as
--    "Past client" reviews, separate from jobs booked through Orbyt. One reminder goes out after 5 days.
-- Safe to run more than once.

-- ---------- 1. Business details from the vendor Review & Agree step ----------
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

-- ---------- 2. Review requests to past clients ----------
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
