-- Orbyt update 23: agents can delete their own projects
-- 1. The agent who created a project can delete it. Teammates can still edit it but not delete it.
-- 2. A project with a booked vendor (chosen or confirmed) can't be deleted by an agent, since the job and Orbyt's fee
--    depend on it. Ashleigh can still delete any project.
-- 3. Vendors who were still quoting get a short email that the project was canceled, and Ashleigh gets a note.
-- Safe to run more than once.

drop policy if exists projects_remove on public.projects;
create policy projects_remove on public.projects for delete to authenticated
  using (public.is_admin() or agent_id = auth.uid());

create or replace function public.projects_delete_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare r record; who text;
begin
  if not public.is_admin() and exists (select 1 from public.bids b where b.project_id = old.id and b.status in ('chosen', 'selected')) then
    raise exception 'This project has a booked vendor, so it can''t be deleted. Email ashleigh@orbytconnect.com if the job fell through.';
  end if;
  -- vendors still quoting hear that it's canceled
  for r in select distinct b.vendor_id, b.category from public.bids b
            where b.project_id = old.id and b.status in ('requested', 'submitted', 'changes') loop
    perform public.orbyt_email(array[public.vendor_email(r.vendor_id)],
      'Project canceled: ' || coalesce(old.address, 'a home'), 'This project was canceled',
      public.ep('The agent canceled the project at <b>' || public.h(coalesce(old.address, 'this home')) || '</b>, so there''s nothing more to do on your '
        || public.h(lower(coalesce(r.category, 'request'))) || ' request. Thanks for your time on it.'),
      'Open your dashboard', 'vendor_project_canceled');
  end loop;
  if not public.is_admin() then
    select coalesce(full_name, email) into who from public.profiles where id = auth.uid();
    perform public.orbyt_email(array[public.admin_email()], 'Project deleted: ' || coalesce(old.address, 'a project'), 'An agent deleted a project',
      public.ep('<b>' || public.h(coalesce(who, 'An agent')) || '</b> deleted the project at <b>' || public.h(coalesce(old.address, '')) || '</b>.'),
      'Open your portal', 'admin_project_deleted');
  end if;
  return old;
end $$;
revoke execute on function public.projects_delete_guard() from public, anon, authenticated;
drop trigger if exists projects_delete_guard on public.projects;
create trigger projects_delete_guard before delete on public.projects
  for each row execute function public.projects_delete_guard();
