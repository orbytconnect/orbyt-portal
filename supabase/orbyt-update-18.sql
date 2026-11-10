-- Orbyt update 18: push notifications
-- 1. People turn on notifications in the portal (phone app or computer). Each device's subscription is saved here.
-- 2. Every email Orbyt sends also goes out as a push notification to the people it's addressed to, on every device
--    they've turned notifications on for.
-- 3. The alerts are delivered by a small sender at portal.orbytconnect.com/.netlify/functions/push. The database
--    gives it a one-time job token; the sender trades the token for the job, sends it, and reports back. The signing
--    key lives only in Supabase's Vault. Ashleigh creates it once with "Set up push notifications" in her portal.
-- Safe to run more than once.

create table if not exists public.push_subscriptions (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  endpoint    text not null unique check (endpoint ~ '^https://'),
  p256dh      text not null,
  auth        text not null,
  user_agent  text,
  created_at  timestamptz not null default now(),
  last_ok_at  timestamptz
);
alter table public.push_subscriptions enable row level security;
drop policy if exists push_subs_own on public.push_subscriptions;
create policy push_subs_own on public.push_subscriptions for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
revoke all on public.push_subscriptions from anon;
grant select, insert, update, delete on public.push_subscriptions to authenticated;

-- one row per batch of alerts; only the sender, holding the token, can read it
create table if not exists public.push_jobs (
  id          uuid primary key default gen_random_uuid(),
  token       text not null,
  title       text not null,
  body        text,
  url         text,
  tag         text,
  subs        jsonb not null,
  created_at  timestamptz not null default now(),
  claimed_at  timestamptz,
  done_at     timestamptz,
  sent        integer
);
alter table public.push_jobs enable row level security;
revoke all on public.push_jobs from anon, authenticated;

-- Ashleigh's one-time setup: the browser makes the key pair, the private half goes straight into the Vault
create or replace function public.push_setup(p_public text, p_private text) returns void
language plpgsql security definer set search_path = '' as $$
declare sid uuid;
begin
  if not public.is_admin() then raise exception 'Only Orbyt can set up notifications.'; end if;
  if p_public !~ '^[A-Za-z0-9_-]{80,100}$' or p_private !~ '^[A-Za-z0-9_-]{40,50}$' then raise exception 'Those keys don''t look right.'; end if;
  select id into sid from vault.decrypted_secrets where name = 'vapid_private' limit 1;
  if sid is null then perform vault.create_secret(p_private, 'vapid_private', 'Orbyt push notification signing key');
  else perform vault.update_secret(sid, p_private); end if;
  insert into public.settings (key, value, is_public)
  values ('push', jsonb_build_object('public_key', p_public, 'subject', 'mailto:ashleigh@orbytconnect.com',
                                     'sender', 'https://portal.orbytconnect.com/.netlify/functions/push'), true)
  on conflict (key) do update set value = public.settings.value || excluded.value, is_public = true;
  -- a new key means old subscriptions won't work any more
  delete from public.push_subscriptions where true;
end $$;
revoke execute on function public.push_setup(text, text) from public, anon;
grant execute on function public.push_setup(text, text) to authenticated;

-- queue alerts for the people an email is addressed to (called from orbyt_email)
create or replace function public.orbyt_push(p_to text[], p_title text, p_body text, p_kind text) returns void
language plpgsql security definer set search_path = '' as $$
declare cfg jsonb; subs jsonb; tok text; jid uuid; txt text; url text;
begin
  select value into cfg from public.settings where key = 'push';
  if cfg is null or coalesce(cfg ->> 'public_key', '') = '' or coalesce(cfg ->> 'enabled', 'true') = 'false' then return; end if;
  select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth)) into subs
    from public.push_subscriptions s join public.profiles p on p.id = s.user_id
   where lower(p.email) in (select lower(trim(x)) from unnest(p_to) as x where x is not null);
  if subs is null then return; end if;
  txt := regexp_replace(regexp_replace(coalesce(p_body, ''), '<[^>]+>', ' ', 'g'), '\s+', ' ', 'g');
  txt := replace(replace(replace(replace(replace(replace(txt, '&amp;', '&'), '&ldquo;', '“'), '&rdquo;', '”'), '&#39;', ''''), '&quot;', '"'), '&nbsp;', ' ');
  txt := trim(txt);
  if length(txt) > 180 then txt := left(txt, 177) || '...'; end if;
  select coalesce((select value ->> 'portal_url' from public.settings where key = 'email'), 'https://portal.orbytconnect.com') into url;
  tok := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  delete from public.push_jobs where created_at < now() - interval '7 days';
  insert into public.push_jobs (token, title, body, url, tag, subs) values (tok, left(coalesce(p_title, 'Orbyt'), 120), txt, url, p_kind, subs)
  returning id into jid;
  perform net.http_post(url := cfg ->> 'sender', body := jsonb_build_object('id', jid, 'token', tok),
                        headers := jsonb_build_object('Content-Type', 'application/json'));
exception when others then
  raise warning 'Orbyt push not sent: %', sqlerrm;
end $$;
revoke execute on function public.orbyt_push(text[], text, text, text) from public, anon, authenticated;

-- the sender trades its one-time token for the job (and the signing key), within 10 minutes, once
create or replace function public.push_claim(p_id uuid, p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare j public.push_jobs%rowtype; cfg jsonb; k text;
begin
  update public.push_jobs set claimed_at = now()
   where id = p_id and token = p_token and claimed_at is null and created_at > now() - interval '10 minutes'
  returning * into j;
  if j.id is null then return null; end if;
  select value into cfg from public.settings where key = 'push';
  select decrypted_secret into k from vault.decrypted_secrets where name = 'vapid_private' limit 1;
  if k is null then return null; end if;
  return jsonb_build_object('title', j.title, 'body', j.body, 'url', j.url, 'tag', j.tag, 'subs', j.subs,
                            'public_key', cfg ->> 'public_key', 'private_key', k, 'subject', cfg ->> 'subject');
end $$;
revoke execute on function public.push_claim(uuid, text) from public;
grant execute on function public.push_claim(uuid, text) to anon;

-- the sender reports back; devices that have turned notifications off are removed
create or replace function public.push_done(p_id uuid, p_token text, p_gone text[], p_sent integer) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.push_jobs set done_at = now(), sent = p_sent where id = p_id and token = p_token and claimed_at is not null and done_at is null;
  if not found then return; end if;
  delete from public.push_subscriptions where endpoint = any (coalesce(p_gone, '{}'))
    and endpoint in (select e ->> 'endpoint' from public.push_jobs j, jsonb_array_elements(j.subs) e where j.id = p_id);
  update public.push_subscriptions set last_ok_at = now()
   where endpoint in (select e ->> 'endpoint' from public.push_jobs j, jsonb_array_elements(j.subs) e where j.id = p_id)
     and not (endpoint = any (coalesce(p_gone, '{}')));
end $$;
revoke execute on function public.push_done(uuid, text, text[], integer) from public;
grant execute on function public.push_done(uuid, text, text[], integer) to anon;

-- every Orbyt email also goes out as a push notification
CREATE OR REPLACE FUNCTION public.orbyt_email(p_to text[], p_subject text, p_heading text, p_body text, p_button text, p_kind text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
as $$
declare
  cfg  jsonb;
  k    text;
  addr text;
  html text;
  rid  bigint;
begin
  -- the same message as a push notification, to anyone who turned notifications on
  begin perform public.orbyt_push(p_to, p_subject, p_body, p_kind); exception when others then raise warning 'Orbyt push skipped: %', sqlerrm; end;
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
