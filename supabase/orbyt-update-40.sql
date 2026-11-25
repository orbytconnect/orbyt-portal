-- Orbyt update 40: text message consent (TCPA)
-- An optional, unchecked box at sign-up, and a setting in My details, record whether someone agreed to texts.
-- Each change is kept as its own row (who, phone, the exact wording they saw, when, and their browser), so there's a record of consent and opt-outs.
-- Safe to run more than once.

create table if not exists public.sms_consents (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references auth.users (id) on delete set null,
  email       text,
  phone       text,
  granted     boolean not null,
  wording     text,
  version     text,
  source      text not null default 'portal' check (source in ('signup', 'portal', 'admin')),
  created_at  timestamptz not null default now(),
  user_agent  text
);
create index if not exists sms_consents_user_idx on public.sms_consents (user_id, created_at desc);
alter table public.sms_consents enable row level security;
drop policy if exists sms_consents_read on public.sms_consents;
-- people see their own record; Ashleigh sees everyone's. Rows are only written by the functions below.
create policy sms_consents_read on public.sms_consents for select to authenticated
  using (public.is_admin() or user_id = auth.uid());
grant select on public.sms_consents to authenticated;

-- at sign-up: record the box only if it was checked
create or replace function public.sms_consent_signup()
returns trigger language plpgsql security definer set search_path = '' as $$
declare m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  if coalesce((m ->> 'sms_consent')::boolean, false) then
    insert into public.sms_consents (user_id, email, phone, granted, wording, version, source, user_agent)
    values (new.id, lower(new.email), nullif(trim(m ->> 'phone'), ''), true,
            left(m ->> 'sms_consent_text', 2000), left(m ->> 'sms_consent_version', 60), 'signup', left(m ->> 'user_agent', 300));
  end if;
  return new;
exception when others then
  raise warning 'sms_consent_signup: %', sqlerrm;  -- never block a sign-up over this
  return new;
end $$;
revoke execute on function public.sms_consent_signup() from public, anon, authenticated;
drop trigger if exists on_auth_user_sms_consent on auth.users;
create trigger on_auth_user_sms_consent after insert on auth.users
  for each row execute function public.sms_consent_signup();

-- later: turn texts on or off from My details
create or replace function public.sms_consent_set(p_granted boolean, p_phone text, p_wording text, p_version text, p_user_agent text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  insert into public.sms_consents (user_id, email, phone, granted, wording, version, source, user_agent)
  values (auth.uid(), (select lower(email) from auth.users where id = auth.uid()), nullif(trim(p_phone), ''), p_granted,
          left(p_wording, 2000), left(p_version, 60), 'portal', left(p_user_agent, 300));
end $$;
revoke execute on function public.sms_consent_set(boolean, text, text, text, text) from public, anon;
grant execute on function public.sms_consent_set(boolean, text, text, text, text) to authenticated;

-- Ashleigh records an opt-out someone sent by text (they replied STOP to your phone)
create or replace function public.sms_consent_admin_optout(p_user uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Not allowed'; end if;
  insert into public.sms_consents (user_id, email, phone, granted, wording, source)
  select p_user, lower(u.email), p.phone, false, 'Opted out by text (recorded by Orbyt)', 'admin'
    from auth.users u left join public.profiles p on p.id = u.id where u.id = p_user;
end $$;
revoke execute on function public.sms_consent_admin_optout(uuid) from public, anon;
grant execute on function public.sms_consent_admin_optout(uuid) to authenticated;

notify pgrst, 'reload schema';
