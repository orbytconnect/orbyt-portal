-- Orbyt update 19: closing partners become an open marketing directory
-- Closing partners (lenders, title, escrow, insurance) pay for marketing, never for referrals. So:
-- 1. Every active agent can see every listed closing partner (licensed, approved, and not paused). Orbyt no longer
--    hand-picks or introduces one, and there's no "closing partner request" email to Ashleigh.
-- 2. The approval email describes a marketing listing: free for 90 days, then $20 a month.
-- 3. Ashleigh can record that a listing is paid through a date.
-- Safe to run more than once.

alter table public.vendor_admin add column if not exists listing_paid_through date;

drop trigger if exists projects_closing_notify on public.projects;

-- agents see the whole directory of listed closing partners
CREATE OR REPLACE FUNCTION public.can_see_vendor(vid uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
as $$
  select public.is_admin()
      or vid = public.my_vendor_id()
      or exists (select 1 from public.bids b where b.vendor_id = vid and public.on_project(b.project_id))
      or exists (select 1 from public.favorites f where f.user_id = auth.uid() and f.vendor_id = vid)
      or exists (select 1 from public.intros i where i.vendor_id = vid and public.on_project(i.project_id))
      -- listed closing partners are an open directory for every active agent
      or (exists (select 1 from public.profiles me where me.id = auth.uid() and me.role = 'agent' and me.status = 'active')
          and exists (select 1 from public.vendors v join public.vendor_admin a on a.vendor_id = v.id
                       where v.id = vid and v.kind = 'closing' and a.approved and coalesce(v.available, true)))
$$;

-- the approval email for closing partners
CREATE OR REPLACE FUNCTION public.profiles_notify()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
as $$
declare
  meta jsonb;
  who  text;
begin
  if tg_op = 'INSERT' then
    if new.status = 'pending' then
      select raw_user_meta_data into meta from auth.users where id = new.id;
      who := coalesce(nullif(trim(meta ->> 'company'), ''), new.full_name, new.email);
      perform public.orbyt_email(array[public.admin_email()],
        'New ' || new.role || ' sign-up: ' || who, 'New ' || new.role || ' sign-up',
        public.ep('<b>' || public.h(who) || '</b>' || case when new.role = 'vendor' and coalesce(meta ->> 'full_name', '') <> '' then ' (' || public.h(meta ->> 'full_name') || ')' else '' end
                  || ' just joined as ' || case when new.role = 'vendor' then 'a vendor partner' else 'an agent' end || '. ' || public.h(new.email)
                  || case when coalesce(new.phone, '') <> '' then ', ' || public.h(new.phone) else '' end || '.')
        || case when coalesce(meta ->> 'services', '') <> '' then public.ep('Services: ' || public.h(array_to_string(public.jsonb_text_array(meta -> 'services'), ', '))) else '' end
        || case when cardinality(new.areas) > 0 then public.ep('Areas: ' || public.h(array_to_string(new.areas, ', '))) else '' end
        || case when coalesce(new.brokerage, '') <> '' then public.ep('Brokerage: ' || public.h(new.brokerage)) else '' end,
        'Review in Orbyt', 'admin_signup');
    end if;
    return new;
  end if;
  if new.status = 'active' and old.status = 'pending' then
    if new.role = 'vendor' and exists (select 1 from public.vendors where user_id = new.id and kind = 'closing') then
      perform public.orbyt_email(array[new.email], 'Your Orbyt closing partner listing is live', 'You''re listed, ' || public.first_name(new.full_name),
        public.ep('Thanks for your patience while I checked your license. Your listing is now live in the Orbyt closing partner directory, where agents in the network can find you and your business overview.')
        || public.ep('Your first 90 days are free. After that, your marketing listing is $20 a month, and you can cancel anytime.'),
        'Sign in to Orbyt', 'approved');
    elsif new.role = 'vendor' then
      perform public.orbyt_email(array[new.email], 'You''re approved for the Orbyt network', 'You''re in, ' || public.first_name(new.full_name),
        public.ep('Thanks for your patience while I checked everything. You''re approved as an Orbyt vendor partner.')
        || public.ep('When you sign in, you''ll see exactly what Orbyt costs (you only pay when an introduction turns into a paid job) and the insurance paperwork your services need.'),
        'Sign in to Orbyt', 'approved');
    elsif new.role = 'agent' then
      perform public.orbyt_email(array[new.email], 'You''re approved for Orbyt', 'You''re in, ' || public.first_name(new.full_name),
        public.ep('Your Orbyt account is ready. Add your first project with the address and what the home needs, and I''ll start lining up vendors matched to it.')
        || public.ep('You''ll get an email here as soon as bids come in.'),
        'Start a project', 'approved');
    end if;
  end if;
  return new;
exception when others then
  raise warning 'Orbyt sign-up email skipped: %', sqlerrm;
  return new;
end $$;
