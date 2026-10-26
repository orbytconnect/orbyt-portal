-- Orbyt update 9: delete, edit and reassign
-- Adds Delete and Edit on the Agents tab and vendor cards (Ashleigh only), Change agent on projects,
-- and My details for agents and vendors, including changing their login email.
-- Safe to run more than once.

-- ---------- Ashleigh can delete an agent or vendor (handy for test accounts) ----------
-- Removes the login and profile. For a vendor, also their vendor profile, bids, reviews and notes.
-- For an agent, their projects are deleted only when p_projects is true; otherwise they stay in Ashleigh's desk.
-- Terms of Use acceptance records are kept (with the email) as a record of what was agreed.
create or replace function public.admin_delete_account(p_user uuid default null, p_vendor uuid default null, p_projects boolean default false)
returns void language plpgsql security definer set search_path = '' as $$
declare vid uuid := p_vendor;
begin
  if not public.is_admin() then raise exception 'Only Orbyt can delete accounts.'; end if;
  if p_user is not null and p_user = auth.uid() then raise exception 'You can''t delete your own account.'; end if;
  if p_user is not null and exists (select 1 from public.profiles where id = p_user and role = 'admin') then
    raise exception 'Admin accounts can''t be deleted here.';
  end if;
  if vid is null and p_user is not null then select id into vid from public.vendors where user_id = p_user; end if;
  if p_user is null and vid is not null then select user_id into p_user from public.vendors where id = vid; end if;
  if vid is not null then
    delete from public.bids where vendor_id = vid;
    delete from public.vendors where id = vid;
  end if;
  if p_user is not null then
    if p_projects then delete from public.projects where agent_id = p_user; end if;
    delete from auth.users where id = p_user;
  end if;
end $$;
revoke execute on function public.admin_delete_account(uuid, uuid, boolean) from public, anon;
grant execute on function public.admin_delete_account(uuid, uuid, boolean) to authenticated;

-- ---------- Keep projects and vendor records in step when someone updates their details ----------
create or replace function public.profiles_sync() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.role = 'agent' then
    update public.projects set
      agent_name  = case when new.full_name is distinct from old.full_name and coalesce(new.full_name, '') <> '' then new.full_name else agent_name end,
      agent_phone = case when new.phone is distinct from old.phone then new.phone else agent_phone end,
      brokerage   = case when new.brokerage is distinct from old.brokerage then new.brokerage else brokerage end,
      agent_email = case when new.email is distinct from old.email then new.email else agent_email end
    where agent_id = new.id;
  end if;
  if new.role = 'vendor' then
    update public.vendors set
      contact_name = case when new.full_name is distinct from old.full_name and coalesce(new.full_name, '') <> '' then new.full_name else contact_name end,
      phone        = case when new.phone is distinct from old.phone then new.phone else phone end,
      email        = case when new.email is distinct from old.email then new.email else email end
    where user_id = new.id;
  end if;
  if new.email is distinct from old.email then
    update public.project_members set email = new.email where user_id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists profiles_sync on public.profiles;
create trigger profiles_sync after update of full_name, phone, brokerage, email on public.profiles
  for each row execute function public.profiles_sync();

-- When a login email changes (the person confirmed a new address, or Ashleigh changed it), update their profile too
create or replace function public.auth_email_sync() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.email is distinct from old.email and new.email is not null then
    update public.profiles set email = lower(new.email) where id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists on_auth_email_change on auth.users;
create trigger on_auth_email_change after update of email on auth.users
  for each row execute function public.auth_email_sync();

-- Ashleigh changes someone's login email for them (no confirmation step, so double-check the spelling)
create or replace function public.admin_set_email(p_user uuid, p_email text)
returns void language plpgsql security definer set search_path = '' as $$
declare em text := lower(trim(p_email));
begin
  if not public.is_admin() then raise exception 'Only Orbyt can change someone''s login email.'; end if;
  if em is null or em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That email doesn''t look right.'; end if;
  if exists (select 1 from auth.users where lower(email) = em and id <> p_user) then
    raise exception 'That email already has an Orbyt account.';
  end if;
  update auth.users set email = em, updated_at = now() where id = p_user;
  if to_regclass('auth.identities') is not null then
    execute 'update auth.identities set identity_data = identity_data || jsonb_build_object(''email'', $1), updated_at = now()
             where user_id = $2 and provider = ''email''' using em, p_user;
  end if;
end $$;
revoke execute on function public.admin_set_email(uuid, text) from public, anon;
grant execute on function public.admin_set_email(uuid, text) to authenticated;
revoke execute on function public.profiles_sync() from public, anon, authenticated;
revoke execute on function public.auth_email_sync() from public, anon, authenticated;
