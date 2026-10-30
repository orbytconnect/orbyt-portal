-- Orbyt update 14: vendor business overview PDF
-- Vendors can upload one PDF about their business and what they offer. Agents see it on the vendor's
-- profile and next to their quotes, and clients can open it from the private quotes page their agent shares.
-- The file goes in its own storage bucket with public links (each link has a random file name), because
-- clients on the quotes page aren't signed in. Only the vendor (or Ashleigh) can add or remove it.
-- Safe to run more than once.

alter table public.vendors add column if not exists overview_pdf      text;
alter table public.vendors add column if not exists overview_pdf_name text;

insert into storage.buckets (id, name, public) values ('vendor-public', 'vendor-public', true)
on conflict (id) do update set public = true;

drop policy if exists orbyt_vpublic_write  on storage.objects;
drop policy if exists orbyt_vpublic_remove on storage.objects;
create policy orbyt_vpublic_write on storage.objects for insert to authenticated
  with check (bucket_id = 'vendor-public' and ((storage.foldername(name))[1] = public.my_vendor_id()::text or public.is_admin()));
create policy orbyt_vpublic_remove on storage.objects for delete to authenticated
  using (bucket_id = 'vendor-public' and ((storage.foldername(name))[1] = public.my_vendor_id()::text or public.is_admin()));

-- the private quotes page now includes each vendor's overview PDF
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
                 'overview', v.overview_pdf, 'overview_name', v.overview_pdf_name,
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
revoke execute on function public.client_quotes(text) from public;
grant execute on function public.client_quotes(text) to anon, authenticated;
