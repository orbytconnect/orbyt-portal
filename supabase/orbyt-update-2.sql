-- Orbyt portal: update 2
-- Adds "soonest you can start" to bids and shows it on the client quotes page. Safe to run more than once.
alter table public.bids add column if not exists available_from date;

create or replace function public.client_quotes(p_token text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'address', p.address, 'agent', p.agent_name, 'agent_email', p.agent_email, 'agent_phone', p.agent_phone,
    'target_date', p.target_date, 'client_type', p.client_type,
    'services', coalesce((
      select jsonb_agg(jsonb_build_object('service', c, 'quotes', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'bid_id', b.id, 'vendor', coalesce(v.name, b.vendor_name), 'amount', b.amount, 'days', b.days, 'available_from', b.available_from,
                 'note', b.note, 'booked', b.status in ('chosen', 'selected'), 'quote_name', b.quote_name,
                 'rating', (select round(avg(r.rating)::numeric, 1) from public.reviews r where r.vendor_id = b.vendor_id and r.approved),
                 'review_count', (select count(*) from public.reviews r where r.vendor_id = b.vendor_id and r.approved))
               order by b.submitted_at), '[]'::jsonb)
          from public.bids b left join public.vendors v on v.id = b.vendor_id
         where b.project_id = p.id and b.category = c and b.amount is not null
           and b.status in ('submitted', 'changes', 'chosen', 'selected'))) order by c)
      from unnest(p.categories) as c), '[]'::jsonb))
    from public.client_links l join public.projects p on p.id = l.project_id
   where l.token = p_token and l.revoked_at is null and (l.expires_at is null or l.expires_at > now())
$$;

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
