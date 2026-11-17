-- Orbyt update 31: changing a project's list date
-- Agents (and Ashleigh) can now change a project's list date from the project page.
-- When it changes, vendors quoting or booked on that project get an email and a push notification with the new date.
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

notify pgrst, 'reload schema';
