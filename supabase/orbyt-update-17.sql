-- Orbyt update 17: why a quote didn't win
-- After an agent picks a vendor, they can say why they went another way on each of the other quotes (optional).
-- The vendor sees the reason in the portal and by email. When the reason is price, the vendor also sees roughly
-- how much lower the booked quote was (a range, never the other vendor's price or name).
-- Safe to run more than once.

alter table public.bids add column if not exists lost_reason text;
alter table public.bids add column if not exists lost_note   text check (lost_note is null or length(lost_note) <= 500);
alter table public.bids add column if not exists lost_gap    text;
alter table public.bids add column if not exists lost_at     timestamptz;
alter table public.bids drop constraint if exists bids_lost_reason_ok;
alter table public.bids add constraint bids_lost_reason_ok
  check (lost_reason is null or lost_reason in ('price', 'timing', 'known', 'client', 'scope', 'speed', 'other'));

-- only the agent (or Ashleigh) shares the reason; the price range is worked out here, so no one sees another vendor's quote
create or replace function public.bids_lost() returns trigger language plpgsql security definer set search_path = '' as $$
declare won numeric; pct numeric;
begin
  if new.lost_reason is not distinct from old.lost_reason and new.lost_note is not distinct from old.lost_note then return new; end if;
  if auth.uid() is not null and not public.is_admin() and not coalesce(public.on_project(old.project_id), false) then
    raise exception 'Only the agent can share why they went another way.';
  end if;
  new.lost_at := case when new.lost_reason is null then null else now() end;
  new.lost_gap := null;
  if new.lost_reason = 'price' and new.amount is not null and new.amount > 0 then
    select b.amount into won from public.bids b
     where b.project_id = new.project_id and b.category = new.category and b.id <> new.id
       and b.status in ('chosen', 'selected') and b.amount is not null
     order by b.chosen_at desc nulls last limit 1;
    if won is not null and won < new.amount then
      pct := (new.amount - won) / new.amount * 100;
      new.lost_gap := case when pct < 10 then 'less than 10% lower' when pct < 25 then '10 to 25% lower' else 'more than 25% lower' end;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists bids_lost on public.bids;
create trigger bids_lost before update of lost_reason, lost_note on public.bids for each row execute function public.bids_lost();
revoke execute on function public.bids_lost() from public, anon, authenticated;

-- email the vendor the first time a reason is shared
create or replace function public.bids_lost_notify() returns trigger language plpgsql security definer set search_path = '' as $$
declare p public.projects%rowtype; v public.vendors%rowtype; why text;
begin
  if new.lost_reason is null or old.lost_reason is not null or new.vendor_id is null then return new; end if;
  select * into p from public.projects where id = new.project_id;
  select * into v from public.vendors where id = new.vendor_id;
  why := case new.lost_reason
    when 'price' then 'Another quote came in lower' || case when new.lost_gap is not null then ', ' || new.lost_gap || ' than yours' else '' end || '.'
    when 'timing' then 'The timing didn''t work for this one.'
    when 'known' then 'They went with a vendor they''ve worked with before.'
    when 'client' then 'The client chose another vendor.'
    when 'scope' then 'Another quote was a better fit for the scope.'
    when 'speed' then 'Another vendor got back sooner.'
    else 'They shared a note below.' end;
  perform public.orbyt_email(array[public.vendor_email(new.vendor_id)],
    'Feedback on your ' || lower(new.category) || ' quote for ' || coalesce(p.address, 'a project'),
    'Feedback on your quote',
    public.ep('Hi ' || public.h(public.first_name(coalesce(v.contact_name, v.name))) || ', ' || public.h(public.first_name(p.agent_name)) || ' shared why they went another way on the '
      || public.h(lower(new.category)) || ' at ' || public.h(coalesce(p.address, 'their project')) || ':')
    || public.ep('<b>' || public.h(why) || '</b>')
    || case when coalesce(new.lost_note, '') <> '' then public.ep('Their note: &ldquo;' || public.h(new.lost_note) || '&rdquo;') else '' end
    || public.ep('Feedback like this is rare, so I wanted you to have it. I''ll keep introducing you to agents who need what you do.'),
    'See my requests', 'lost_reason');
  return new;
exception when others then
  raise warning 'Orbyt feedback email skipped: %', sqlerrm;
  return new;
end $$;
drop trigger if exists bids_lost_notify on public.bids;
create trigger bids_lost_notify after update of lost_reason on public.bids for each row execute function public.bids_lost_notify();
revoke execute on function public.bids_lost_notify() from public, anon, authenticated;
