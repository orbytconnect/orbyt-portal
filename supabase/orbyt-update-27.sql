-- Orbyt update 27: messages with Ashleigh
-- 1. Every agent, vendor and closing partner has one conversation with Ashleigh at Orbyt, not tied to a property.
--    Either side can start it. Ashleigh can start one with anyone from her Messages tab.
-- 2. These are Ashleigh's own conversations, so she gets a push for each message and the 15-minute email backup,
--    and so does the other person. Agent and vendor job threads stay read only for her, with no notifications.
-- Needs update 24 first. Safe to run more than once.

alter table public.message_threads alter column project_id drop not null;
alter table public.message_threads alter column vendor_id drop not null;
alter table public.message_threads add column if not exists orbyt_user uuid references auth.users (id) on delete cascade;
create unique index if not exists message_threads_orbyt_user on public.message_threads (orbyt_user) where orbyt_user is not null;
do $$ begin
  alter table public.message_threads add constraint message_threads_shape check
    ((orbyt_user is null and project_id is not null and vendor_id is not null) or (orbyt_user is not null and project_id is null and vendor_id is null));
exception when duplicate_object then null; end $$;
alter table public.messages drop constraint if exists messages_sender_side_check;
alter table public.messages add constraint messages_sender_side_check check (sender_side in ('agent', 'vendor', 'orbyt', 'member'));

create or replace function public.can_see_thread(tid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.message_threads t where t.id = tid
                  and (public.is_admin() or t.orbyt_user = auth.uid()
                       or (t.orbyt_user is null and (public.on_project(t.project_id) or t.vendor_id = public.my_vendor_id()))))
$$;

create or replace function public.thread_members(tid uuid) returns table (email text, side text)
language sql stable security definer set search_path = '' as $$
  select distinct lower(x.email), x.side from (
    select p.agent_email as email, 'agent' as side from public.message_threads t join public.projects p on p.id = t.project_id where t.id = tid
    union all
    select m.email, 'agent' from public.message_threads t join public.project_members m on m.project_id = t.project_id where t.id = tid
    union all
    select public.vendor_email(t.vendor_id), 'vendor' from public.message_threads t where t.id = tid and t.vendor_id is not null
    union all
    select u.email, 'member' from public.message_threads t join public.profiles u on u.id = t.orbyt_user where t.id = tid
    union all
    select public.admin_email(), 'orbyt' from public.message_threads t where t.id = tid and t.orbyt_user is not null
  ) x where coalesce(x.email, '') like '%_@_%'
$$;
revoke execute on function public.thread_members(uuid) from public, anon, authenticated;

-- send to or from Ashleigh: she names the person; anyone else writes in their own conversation
create or replace function public.orbyt_message_send(p_user uuid, p_body text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare uid uuid; side text; tid uuid; me_email text := public.my_email(); me_name text; recips text[]; base text; who public.profiles%rowtype;
begin
  if length(trim(coalesce(p_body, ''))) = 0 then raise exception 'Write a message first.'; end if;
  if length(p_body) > 4000 then raise exception 'That message is too long. Keep it under 4,000 characters.'; end if;
  if public.is_admin() then uid := p_user; side := 'orbyt'; me_name := 'Ashleigh at Orbyt';
  else uid := auth.uid(); side := 'member'; end if;
  select * into who from public.profiles where id = uid;
  if who.id is null then raise exception 'That account isn''t available.'; end if;
  if uid = auth.uid() and public.is_admin() then raise exception 'Pick someone to message.'; end if;
  if side = 'member' then
    me_name := coalesce((select v.name from public.vendors v where v.user_id = uid limit 1), nullif(trim(who.full_name), ''), who.email);
  end if;
  insert into public.message_threads (orbyt_user) values (uid)
  on conflict (orbyt_user) where orbyt_user is not null do update set orbyt_user = excluded.orbyt_user
  returning id into tid;
  insert into public.messages (thread_id, sender_id, sender_email, sender_name, sender_side, body)
  values (tid, auth.uid(), me_email, me_name, side, trim(p_body));
  update public.message_threads set last_message_at = now() where id = tid;
  insert into public.message_reads (thread_id, email, last_read_at) values (tid, me_email, now())
  on conflict (thread_id, email) do update set last_read_at = now();
  select array_agg(m.email) into recips from public.thread_members(tid) m where m.email <> me_email;
  base := coalesce((select value ->> 'portal_url' from public.settings where key = 'email'), 'https://portal.orbytconnect.com');
  if recips is not null then
    perform public.orbyt_push(recips, me_name, trim(p_body), 'message', base || '/?thread=' || tid);
  end if;
  return tid;
end $$;
revoke execute on function public.orbyt_message_send(uuid, text) from public, anon;
grant execute on function public.orbyt_message_send(uuid, text) to authenticated;

-- reading: Ashleigh's reading counts in her own conversations, not in agent and vendor threads
create or replace function public.message_read(p_thread uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.can_see_thread(p_thread) then return; end if;
  if public.is_admin() and not exists (select 1 from public.message_threads where id = p_thread and orbyt_user is not null) then return; end if;
  insert into public.message_reads (thread_id, email, last_read_at) values (p_thread, public.my_email(), now())
  on conflict (thread_id, email) do update set last_read_at = now();
end $$;

-- the email backup covers conversations with Ashleigh too
create or replace function public.messages_digest_run() returns integer
language plpgsql security definer set search_path = '' as $$
declare r record; n integer := 0; rows text;
begin
  perform set_config('orbyt.no_push', 'on', true);
  for r in
    with pending as (
      select tm.email, t.id as thread_id,
             case when t.orbyt_user is null then p.address
                  when tm.side = 'orbyt' then coalesce((select v2.name from public.vendors v2 where v2.user_id = t.orbyt_user limit 1), u.full_name, u.email)
                  else 'Ashleigh at Orbyt' end as address,
             v.name as vendor_name, tm.side,
             count(*) as cnt, max(m.created_at) as last_at,
             (array_agg(m.sender_name order by m.created_at desc))[1] as last_from,
             (array_agg(m.body order by m.created_at desc))[1] as last_body
        from public.message_threads t
        left join public.projects p on p.id = t.project_id
        left join public.vendors v on v.id = t.vendor_id
        left join public.profiles u on u.id = t.orbyt_user
        cross join lateral public.thread_members(t.id) tm
        join public.messages m on m.thread_id = t.id and lower(coalesce(m.sender_email, '')) <> tm.email
        left join public.message_reads rd on rd.thread_id = t.id and rd.email = tm.email
       where t.last_message_at > now() - interval '7 days'
         and m.created_at > greatest(coalesce(rd.last_read_at, '-infinity'), coalesce(rd.last_emailed_at, '-infinity'))
       group by tm.email, t.id, t.orbyt_user, p.address, v.name, u.full_name, u.email, tm.side
      having min(m.created_at) <= now() - interval '15 minutes')
    select email, jsonb_agg(jsonb_build_object('thread', thread_id, 'address', address, 'vendor', vendor_name, 'side', side, 'n', cnt,
                                                'from', last_from, 'body', last_body) order by last_at desc) as threads,
           sum(cnt) as total
      from pending group by email
  loop
    select string_agg(
             '<div style="border-left:3px solid #A8871F;padding:4px 0 4px 12px;margin:0 0 14px">'
          || '<div style="font-size:15px;color:#18314F"><b>' || public.h(coalesce(x ->> 'address', 'A conversation')) || '</b>'
          || case when x ->> 'side' = 'agent' then ' · ' || public.h(coalesce(x ->> 'vendor', '')) else '' end || '</div>'
          || '<div style="font-size:14px;color:#2C4260;margin-top:4px">' || public.h(coalesce(x ->> 'from', 'Someone')) || ': '
          || public.h(left(coalesce(x ->> 'body', ''), 240)) || case when length(coalesce(x ->> 'body', '')) > 240 then '...' else '' end || '</div>'
          || case when (x ->> 'n')::int > 1 then '<div style="font-size:13px;color:#5A6B80;margin-top:2px">' || (x ->> 'n') || ' unread messages</div>' else '' end
          || '</div>', '')
      into rows from jsonb_array_elements(r.threads) x;
    perform public.orbyt_email(array[r.email],
      case when r.total = 1 then 'New message in Orbyt' else r.total || ' new messages in Orbyt' end,
      case when r.total = 1 then 'You have a new message' else 'You have ' || r.total || ' new messages' end,
      rows || public.ep('Reply in Orbyt so everything stays in one place.'),
      'Read and reply', 'message_digest');
    insert into public.message_reads (thread_id, email, last_emailed_at)
    select (x ->> 'thread')::uuid, r.email, now() from jsonb_array_elements(r.threads) x
    on conflict (thread_id, email) do update set last_emailed_at = now();
    n := n + 1;
  end loop;
  perform set_config('orbyt.no_push', '', true);
  return n;
end $$;
revoke execute on function public.messages_digest_run() from public, anon, authenticated;
