-- Orbyt update 31
-- 1. Changing a project's list date: vendors quoting or booked on the project get an email and a push with the new date.
-- 2. Project IDs: every project gets a short ID like CA-1001, shown with the address and searchable.
-- 3. Insurance: renewal heads-ups about a month, 2 weeks and 1 week before a certificate expires.
-- 4. Email buttons: makes sure every email's button points to https://portal.orbytconnect.com.
-- Safe to run more than once.

create or replace function public.projects_date_notify() returns trigger
language plpgsql security definer set search_path = '' as $$
declare r record; who text; fmt text;
begin
  if new.target_date is null or new.listed or new.target_date is not distinct from old.target_date then return new; end if;
  select split_part(coalesce(nullif(full_name, ''), 'The agent'), ' ', 1) into who from public.profiles where id = new.agent_id;
  fmt := trim(to_char(new.target_date, 'FMMonth FMDD'));
  for r in select distinct b.vendor_id, string_agg(distinct lower(b.category), ' and ') cats,
                  bool_or(b.status in ('chosen', 'selected')) booked
             from public.bids b
            where b.project_id = new.id and b.status in ('requested', 'submitted', 'changes', 'chosen', 'selected') and not b.done
            group by b.vendor_id loop
    perform public.orbyt_email(array[public.vendor_email(r.vendor_id)],
      'New list date for ' || coalesce(new.address, 'a home') || ': ' || fmt, 'The list date moved',
      public.ep(public.h(coalesce(who, 'The agent')) || ' moved the list date for <b>' || public.h(coalesce(new.address, 'this home')) || '</b>'
        || case when old.target_date is not null then ' from ' || trim(to_char(old.target_date, 'FMMonth FMDD')) else '' end
        || ' to <b>' || fmt || '</b>.')
      || public.ep(case when r.booked then 'Please check that your ' || public.h(r.cats) || ' work still fits the new timeline, and message ' || public.h(coalesce(who, 'the agent')) || ' in Orbyt if anything needs to shift.'
                        else 'If it changes your ' || public.h(r.cats) || ' quote or timing, update it in Orbyt.' end),
      'Open your dashboard', 'vendor_list_date_changed');
    perform public.orbyt_push(array[public.vendor_email(r.vendor_id)], 'New list date: ' || fmt,
      coalesce(new.address, 'A project') || ' now lists ' || fmt || '.', 'vendor_list_date_changed');
  end loop;
  return new;
end $$;
revoke execute on function public.projects_date_notify() from public, anon, authenticated;
drop trigger if exists projects_date_notify on public.projects;
create trigger projects_date_notify after update of target_date on public.projects
  for each row execute function public.projects_date_notify();

-- ---------- 2. Project IDs ----------
alter table public.projects add column if not exists ref_code text;
create unique index if not exists projects_ref_code_key on public.projects (ref_code);
create sequence if not exists public.project_ref_seq start 1001;

create or replace function public.project_ref_for(p_address text) returns text
language sql volatile security definer set search_path = '' as $$
  select coalesce(substring(coalesce(p_address, '') from ',\s*([A-Z]{2})\s*\d{5}'), 'CA') || '-' || nextval('public.project_ref_seq')
$$;
revoke execute on function public.project_ref_for(text) from public, anon, authenticated;

create or replace function public.projects_ref() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and old.ref_code is not null then new.ref_code := old.ref_code; end if;   -- IDs never change once set
  if new.ref_code is null then new.ref_code := public.project_ref_for(new.address); end if;
  return new;
end $$;
revoke execute on function public.projects_ref() from public, anon, authenticated;
drop trigger if exists projects_ref on public.projects;
create trigger projects_ref before insert or update on public.projects for each row execute function public.projects_ref();

-- give existing projects an ID, oldest first
do $$ declare r record; begin
  for r in select id, address from public.projects where ref_code is null order by created_at loop
    update public.projects set ref_code = public.project_ref_for(r.address) where id = r.id and ref_code is null;
  end loop;
end $$;

-- ---------- 3. Insurance renewal heads-ups (30, 14 and 7 days) ----------
create or replace function public.insurance_reminders_run() returns integer language plpgsql security definer set search_path = '' as $$
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
      join public.vendor_admin a on a.vendor_id = v.id and a.approved
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
      -- three heads-ups before it expires: about a month, 2 weeks and 1 week out
      ask := case when exp <= current_date + 7 then '7' when exp <= current_date + 14 then '14' else '30' end;
      if not exists (select 1 from public.insurance_reminders where vendor_id = r.id
                     and kind in ('expiring' || ask || ':' || exp, case when ask = '30' then 'expiring:' || exp end)) then
        perform public.orbyt_email(array[public.vendor_email(r.id)],
          case ask when '7' then 'Your insurance certificate expires in a week' when '14' then 'Your insurance certificate expires in 2 weeks' else 'Your insurance renews next month' end,
          'Insurance renewal coming up',
          public.ep('Hi ' || public.h(public.first_name(r.contact_name)) || ', the certificate of insurance on file with Orbyt is good through '
            || to_char(exp, 'FMMonth FMDD, YYYY') || '. Once your policy renews, please upload the new certificate so introductions keep coming.')
          || case when ask <> '30' then public.ep('Ask your insurance agent for the renewed certificate now (sign in to copy a ready-made request), so there''s no gap.') else '' end,
          'Upload my certificate', 'insurance_expiring');
        insert into public.insurance_reminders (vendor_id, kind) values (r.id, 'expiring' || ask || ':' || exp) on conflict do nothing;
        sent := sent + 1;
      end if;
    end if;
  end loop;
  return sent;
end $$;
revoke execute on function public.insurance_reminders_run() from public, anon, authenticated;

-- ---------- 4. Email button link ----------
update public.settings set value = value || jsonb_build_object('portal_url', 'https://portal.orbytconnect.com')
 where key = 'email' and coalesce(value ->> 'portal_url', '') <> 'https://portal.orbytconnect.com';

notify pgrst, 'reload schema';
