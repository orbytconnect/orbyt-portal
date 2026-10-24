-- Orbyt portal: update 4
-- Notification emails, sent through Resend straight from the database.
-- Safe to run more than once. Emails never block a save: if one can't send, the save still goes through.
--
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
