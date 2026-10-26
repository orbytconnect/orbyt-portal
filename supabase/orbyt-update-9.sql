-- Orbyt update 9: delete agents and vendors from the portal
-- Adds the Delete option on the Agents tab and on vendor cards (Ashleigh only).
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
