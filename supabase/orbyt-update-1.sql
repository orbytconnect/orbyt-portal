-- Orbyt portal: update 1
-- A few extra fields the portal screens save. Safe to run more than once.
alter table public.bids           add column if not exists done_by      text;
alter table public.project_admin  add column if not exists completed_at timestamptz;
alter table public.vendor_private add column if not exists coi_url      text;
alter table public.contacts       add column if not exists area         text;
alter table public.spend          add column if not exists side         text;
alter table public.spend          add column if not exists channel      text;

insert into public.settings (key, value, is_public)
values ('main', '{"matching": "hand"}', true), ('config', '{}', false)
on conflict (key) do nothing;


-- Let a vendor re-report a final amount after the agent confirmed or disputed it.
create or replace function public.bids_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  is_vendor boolean;
  is_agent  boolean;
begin
  -- changes made by the database itself (like reopening quotes) are allowed
  if auth.uid() is null or pg_trigger_depth() > 1 or public.is_admin() then return new; end if;
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
       or new.declined_at is distinct from old.declined_at or new.confirm_note is distinct from old.confirm_note then
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
