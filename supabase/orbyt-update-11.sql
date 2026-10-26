-- Orbyt update 11: agents can remove a service from their project
-- When the client books a service on their own, Ashleigh or the agent can take it off the project.
-- Open requests close, vendors who already bid get the usual note, and Ashleigh gets an email when an agent does it.
-- Safe to run more than once.

create or replace function public.bids_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  is_vendor boolean;
  is_agent  boolean;
begin
  -- changes made by the database itself (like reopening quotes) are allowed
  -- remove_project_service() closes open requests for agents too
  if auth.uid() is null or pg_trigger_depth() > 1 or public.is_admin()
     or current_setting('orbyt.service_removal', true) = 'on' then return new; end if;
  is_vendor := coalesce(old.vendor_id = public.my_vendor_id(), false);
  is_agent  := coalesce(public.on_project(old.project_id), false);

  if new.project_id is distinct from old.project_id or new.vendor_id is distinct from old.vendor_id
     or new.vendor_name is distinct from old.vendor_name or new.category is distinct from old.category
     or new.introduced_at is distinct from old.introduced_at or new.introduced_by is distinct from old.introduced_by
     or new.intro_note is distinct from old.intro_note or new.avail_checked is distinct from old.avail_checked
     or new.suggest_rank is distinct from old.suggest_rank or new.requested_at is distinct from old.requested_at
     or new.fee_type is distinct from old.fee_type then
    raise exception 'Only Orbyt can change that part of a bid.';
  end if;

  if is_vendor and not is_agent then
    if new.step_agreement is distinct from old.step_agreement or new.step_paid is distinct from old.step_paid
       or new.chosen_at is distinct from old.chosen_at or new.change_note is distinct from old.change_note
       or new.changes_at is distinct from old.changes_at or new.changes_by is distinct from old.changes_by
       -- a vendor can clear the agent's confirmation or dispute (by reporting a new final amount), never set them
       or (new.final_confirmed_at is distinct from old.final_confirmed_at and new.final_confirmed_at is not null)
       or (new.final_dispute is distinct from old.final_dispute and new.final_dispute is not null) then
      raise exception 'That change has to come from the agent.';
    end if;
    if new.status is distinct from old.status and not (
         (old.status in ('requested', 'changes') and new.status in ('submitted', 'declined'))
      or (old.status = 'chosen' and new.status in ('selected', 'declined'))) then
      raise exception 'A vendor can''t move a bid from % to %.', old.status, new.status;
    end if;
    return new;
  end if;

  if is_agent and not is_vendor then
    if new.amount is distinct from old.amount or new.days is distinct from old.days or new.note is distinct from old.note
       or new.quote_path is distinct from old.quote_path or new.quote_name is distinct from old.quote_name
       or new.quote_is_image is distinct from old.quote_is_image or new.submitted_at is distinct from old.submitted_at
       or new.rev is distinct from old.rev or new.prev_amount is distinct from old.prev_amount
       or new.final_amount is distinct from old.final_amount or new.final_note is distinct from old.final_note
       or new.final_reported_by is distinct from old.final_reported_by or new.final_reported_at is distinct from old.final_reported_at
       or new.decline_reason is distinct from old.decline_reason or new.decline_stage is distinct from old.decline_stage
       or new.declined_at is distinct from old.declined_at or new.confirm_note is distinct from old.confirm_note
       or new.available_from is distinct from old.available_from then
      raise exception 'That change has to come from the vendor.';
    end if;
    if new.status is distinct from old.status and not (
         (old.status = 'submitted' and new.status in ('chosen', 'passed', 'changes'))
      or (old.status in ('chosen', 'selected', 'passed') and new.status = 'submitted')) then
      raise exception 'An agent can''t move a bid from % to %.', old.status, new.status;
    end if;
    return new;
  end if;

  if is_agent and is_vendor then return new; end if;
  raise exception 'You don''t have access to this bid.';
end $$;


-- Remove a service from a project (the client booked it on their own). Ashleigh or an agent on the project can do it,
-- as long as nobody is chosen or booked for it and the home isn't listed yet. Open requests close (vendors who already
-- bid get the usual "went another way" email). When an agent does it, Ashleigh gets an email.
create or replace function public.remove_project_service(p_project uuid, p_category text)
returns void language plpgsql security definer set search_path = '' as $$
declare p public.projects%rowtype; who text; n integer;
begin
  select * into p from public.projects where id = p_project for update;
  if p.id is null or not (public.is_admin() or public.on_project(p.id)) then
    raise exception 'You can only remove a service from a project you''re on.';
  end if;
  if p.listed then raise exception 'You can only remove a service before the home is listed.'; end if;
  if not (p_category = any (p.categories)) then return; end if;
  if exists (select 1 from public.bids where project_id = p.id and category = p_category and status in ('chosen', 'selected')) then
    raise exception 'You can only remove a service that nobody is booked for yet.';
  end if;
  perform set_config('orbyt.service_removal', 'on', true);
  update public.bids set status = 'passed'
   where project_id = p.id and category = p_category and status in ('requested', 'submitted', 'changes');
  get diagnostics n = row_count;
  perform set_config('orbyt.service_removal', 'off', true);
  update public.projects set categories = array_remove(categories, p_category) where id = p.id;
  if not public.is_admin() then
    select coalesce(nullif(full_name, ''), email) into who from public.profiles where id = auth.uid();
    perform public.orbyt_email(array[public.admin_email()],
      coalesce(who, 'An agent') || ' removed ' || lower(p_category) || ' from ' || p.address,
      'A service came off a project',
      public.ep('<b>' || public.h(coalesce(who, 'An agent')) || '</b> removed <b>' || public.h(lower(p_category)) || '</b> from '
        || public.h(p.address) || ', so the client is handling it on their own.')
      || public.ep(case when n = 0 then 'No vendor requests were open for it.'
                        when n = 1 then '1 open request closed.'
                        else n || ' open requests closed.' end),
      'Open your dashboard', 'admin_service_removed');
  end if;
end $$;
revoke execute on function public.remove_project_service(uuid, text) from public, anon;
grant execute on function public.remove_project_service(uuid, text) to authenticated;
