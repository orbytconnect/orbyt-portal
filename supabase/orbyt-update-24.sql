-- Orbyt update 24: messages between agents and vendors
-- 1. Each vendor on a project has one thread with the agent's side (the agent and anyone the project is shared with),
--    labeled with the property address. Closing partners aren't part of messaging.
-- 2. Every message sends a push notification right away to the other side. Nothing is grouped.
-- 3. Email is the backup: if a message is still unread after 15 minutes, the person gets one email covering
--    everything unread, checked every 5 minutes. Reading in the app means no email.
-- 4. Ashleigh can read every thread but doesn't post, and gets no notifications for them.
-- Needs update 18 first. Safe to run more than once.

create table if not exists public.message_threads (
  id               uuid primary key default gen_random_uuid(),
  project_id       uuid not null references public.projects (id) on delete cascade,
  vendor_id        uuid not null references public.vendors (id) on delete cascade,
  created_at       timestamptz not null default now(),
  last_message_at  timestamptz,
  unique (project_id, vendor_id)
);
create table if not exists public.messages (
  id            uuid primary key default gen_random_uuid(),
  thread_id     uuid not null references public.message_threads (id) on delete cascade,
  sender_id     uuid references auth.users (id) on delete set null,
  sender_email  text,
  sender_name   text,
  sender_side   text not null check (sender_side in ('agent', 'vendor')),
  body          text not null check (length(trim(body)) between 1 and 4000),
  created_at    timestamptz not null default now()
);
create index if not exists messages_thread on public.messages (thread_id, created_at);
-- what each person has read, and when they were last emailed about a thread
create table if not exists public.message_reads (
  thread_id        uuid not null references public.message_threads (id) on delete cascade,
  email            text not null,
  last_read_at     timestamptz,
  last_emailed_at  timestamptz,
  primary key (thread_id, email)
);

-- who can see a thread: Ashleigh, the agent's side of the project, and the vendor
create or replace function public.can_see_thread(tid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.message_threads t where t.id = tid
                  and (public.is_admin() or public.on_project(t.project_id) or t.vendor_id = public.my_vendor_id()))
$$;

alter table public.message_threads enable row level security;
alter table public.messages enable row level security;
alter table public.message_reads enable row level security;
drop policy if exists message_threads_read on public.message_threads;
create policy message_threads_read on public.message_threads for select to authenticated using (public.can_see_thread(id));
drop policy if exists messages_read on public.messages;
create policy messages_read on public.messages for select to authenticated using (public.can_see_thread(thread_id));
drop policy if exists message_reads_own on public.message_reads;
create policy message_reads_own on public.message_reads for select to authenticated using (email = public.my_email());
revoke all on public.message_threads, public.messages, public.message_reads from anon;
revoke insert, update, delete on public.message_threads, public.messages, public.message_reads from authenticated;
grant select on public.message_threads, public.messages, public.message_reads to authenticated;

-- everyone on a thread, by email: the agent, people the project is shared with, and the vendor
create or replace function public.thread_members(tid uuid) returns table (email text, side text)
language sql stable security definer set search_path = '' as $$
  select distinct lower(x.email), x.side from (
    select p.agent_email as email, 'agent' as side from public.message_threads t join public.projects p on p.id = t.project_id where t.id = tid
    union all
    select m.email, 'agent' from public.message_threads t join public.project_members m on m.project_id = t.project_id where t.id = tid
    union all
    select public.vendor_email(t.vendor_id), 'vendor' from public.message_threads t where t.id = tid
  ) x where coalesce(x.email, '') like '%_@_%'
$$;
revoke execute on function public.thread_members(uuid) from public, anon, authenticated;

-- push notifications can now link straight to a thread, and can be skipped (for the email digest)
create or replace function public.orbyt_push(p_to text[], p_title text, p_body text, p_kind text, p_url text) returns void
language plpgsql security definer set search_path = '' as $$
declare cfg jsonb; subs jsonb; tok text; jid uuid; txt text; url text;
begin
  if coalesce(current_setting('orbyt.no_push', true), '') = 'on' then return; end if;
  select value into cfg from public.settings where key = 'push';
  if cfg is null or coalesce(cfg ->> 'public_key', '') = '' or coalesce(cfg ->> 'enabled', 'true') = 'false' then return; end if;
  select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth)) into subs
    from public.push_subscriptions s join public.profiles p on p.id = s.user_id
   where lower(p.email) in (select lower(trim(x)) from unnest(p_to) as x where x is not null);
  if subs is null then return; end if;
  txt := regexp_replace(regexp_replace(coalesce(p_body, ''), '<[^>]+>', ' ', 'g'), '\s+', ' ', 'g');
  txt := replace(replace(replace(replace(replace(replace(txt, '&amp;', '&'), '&ldquo;', '“'), '&rdquo;', '”'), '&#39;', ''''), '&quot;', '"'), '&nbsp;', ' ');
  txt := trim(txt);
  if length(txt) > 180 then txt := left(txt, 177) || '...'; end if;
  url := coalesce(p_url, (select value ->> 'portal_url' from public.settings where key = 'email'), 'https://portal.orbytconnect.com');
  tok := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  delete from public.push_jobs where created_at < now() - interval '7 days';
  insert into public.push_jobs (token, title, body, url, tag, subs) values (tok, left(coalesce(p_title, 'Orbyt'), 120), txt, url, p_kind, subs)
  returning id into jid;
  perform net.http_post(url := cfg ->> 'sender', body := jsonb_build_object('id', jid, 'token', tok),
                        headers := jsonb_build_object('Content-Type', 'application/json'));
exception when others then
  raise warning 'Orbyt push not sent: %', sqlerrm;
end $$;
revoke execute on function public.orbyt_push(text[], text, text, text, text) from public, anon, authenticated;
create or replace function public.orbyt_push(p_to text[], p_title text, p_body text, p_kind text) returns void
language sql security definer set search_path = '' as $$ select public.orbyt_push(p_to, p_title, p_body, p_kind, null) $$;
revoke execute on function public.orbyt_push(text[], text, text, text) from public, anon, authenticated;

-- send a message: the agent's side to a vendor on their project, or a vendor to the agent's side
create or replace function public.message_send(p_project uuid, p_vendor uuid, p_body text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare side text; tid uuid; mid uuid; me_email text := public.my_email(); me_name text; p public.projects%rowtype; v public.vendors%rowtype;
        base text; recips text[];
begin
  if length(trim(coalesce(p_body, ''))) = 0 then raise exception 'Write a message first.'; end if;
  if length(p_body) > 4000 then raise exception 'That message is too long. Keep it under 4,000 characters.'; end if;
  select * into p from public.projects where id = p_project;
  select * into v from public.vendors where id = p_vendor;
  if p.id is null or v.id is null then raise exception 'That project or vendor isn''t available.'; end if;
  if v.kind = 'closing' then raise exception 'Messages are between agents and vendor partners.'; end if;
  if not exists (select 1 from public.bids b where b.project_id = p.id and b.vendor_id = v.id) then
    raise exception 'You can message a vendor once they''re on the project.';
  end if;
  if public.on_project(p.id) then side := 'agent';
  elsif v.id = public.my_vendor_id() and public.is_active() then side := 'vendor';
  else raise exception 'Only the agent and the vendor on this project can send messages here.'; end if;
  select coalesce(nullif(trim(full_name), ''), email) into me_name from public.profiles where id = auth.uid();
  if side = 'vendor' then me_name := coalesce(v.name, me_name); end if;
  insert into public.message_threads (project_id, vendor_id) values (p.id, v.id)
  on conflict (project_id, vendor_id) do update set project_id = excluded.project_id
  returning id into tid;
  insert into public.messages (thread_id, sender_id, sender_email, sender_name, sender_side, body)
  values (tid, auth.uid(), me_email, me_name, side, trim(p_body)) returning id into mid;
  update public.message_threads set last_message_at = now() where id = tid;
  insert into public.message_reads (thread_id, email, last_read_at) values (tid, me_email, now())
  on conflict (thread_id, email) do update set last_read_at = now();
  -- a push to everyone else on the thread, right away
  select array_agg(m.email) into recips from public.thread_members(tid) m where m.email <> me_email;
  base := coalesce((select value ->> 'portal_url' from public.settings where key = 'email'), 'https://portal.orbytconnect.com');
  if recips is not null then
    perform public.orbyt_push(recips, me_name || ' · ' || coalesce(p.address, 'Orbyt'), trim(p_body), 'message', base || '/?thread=' || tid);
  end if;
  return tid;
end $$;
revoke execute on function public.message_send(uuid, uuid, text) from public, anon;
grant execute on function public.message_send(uuid, uuid, text) to authenticated;

-- mark a thread read for the signed-in person (Ashleigh's reading isn't tracked)
create or replace function public.message_read(p_thread uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if public.is_admin() or not public.can_see_thread(p_thread) then return; end if;
  insert into public.message_reads (thread_id, email, last_read_at) values (p_thread, public.my_email(), now())
  on conflict (thread_id, email) do update set last_read_at = now();
end $$;
revoke execute on function public.message_read(uuid) from public, anon;
grant execute on function public.message_read(uuid) to authenticated;

-- the email backup: one email per person for messages still unread after 15 minutes
create or replace function public.messages_digest_run() returns integer
language plpgsql security definer set search_path = '' as $$
declare r record; n integer := 0; rows text; base text;
begin
  base := coalesce((select value ->> 'portal_url' from public.settings where key = 'email'), 'https://portal.orbytconnect.com');
  perform set_config('orbyt.no_push', 'on', true);
  for r in
    with pending as (
      select tm.email, t.id as thread_id, p.address, v.name as vendor_name, tm.side,
             count(*) as cnt, max(m.created_at) as last_at,
             (array_agg(m.sender_name order by m.created_at desc))[1] as last_from,
             (array_agg(m.body order by m.created_at desc))[1] as last_body
        from public.message_threads t
        join public.projects p on p.id = t.project_id
        join public.vendors v on v.id = t.vendor_id
        cross join lateral public.thread_members(t.id) tm
        join public.messages m on m.thread_id = t.id and lower(coalesce(m.sender_email, '')) <> tm.email
        left join public.message_reads rd on rd.thread_id = t.id and rd.email = tm.email
       where t.last_message_at > now() - interval '7 days'
         and m.created_at > greatest(coalesce(rd.last_read_at, '-infinity'), coalesce(rd.last_emailed_at, '-infinity'))
       group by tm.email, t.id, p.address, v.name, tm.side
      having min(m.created_at) <= now() - interval '15 minutes')
    select email, jsonb_agg(jsonb_build_object('thread', thread_id, 'address', address, 'vendor', vendor_name, 'side', side, 'n', cnt,
                                                'from', last_from, 'body', last_body) order by last_at desc) as threads,
           sum(cnt) as total
      from pending group by email
  loop
    select string_agg(
             '<div style="border-left:3px solid #A8871F;padding:4px 0 4px 12px;margin:0 0 14px">'
          || '<div style="font-size:15px;color:#18314F"><b>' || public.h(coalesce(x ->> 'address', 'A project')) || '</b>'
          || case when x ->> 'side' = 'agent' then ' · ' || public.h(coalesce(x ->> 'vendor', '')) else '' end || '</div>'
          || '<div style="font-size:14px;color:#2C4260;margin-top:4px">' || public.h(coalesce(x ->> 'from', 'Someone')) || ': '
          || public.h(left(coalesce(x ->> 'body', ''), 240)) || case when length(coalesce(x ->> 'body', '')) > 240 then '...' else '' end || '</div>'
          || case when (x ->> 'n')::int > 1 then '<div style="font-size:13px;color:#5A6B80;margin-top:2px">' || (x ->> 'n') || ' unread messages</div>' else '' end
          || '</div>', '')
      into rows from jsonb_array_elements(r.threads) x;
    perform public.orbyt_email(array[r.email],
      case when r.total = 1 then 'New message in Orbyt' else r.total || ' new messages in Orbyt' end,
      case when r.total = 1 then 'You have a new message' else 'You have ' || r.total || ' new messages' end,
      rows || public.ep('Reply in Orbyt so everything about the job stays in one place.'),
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

do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('orbyt-message-digest', '*/5 * * * *', 'select public.messages_digest_run()');
exception when others then
  raise warning 'Message emails were not scheduled (%). In Supabase, turn on the pg_cron extension under Database, Extensions, then run this script again.', sqlerrm;
end $$;

-- new messages show up live in an open thread
do $$
begin
  alter publication supabase_realtime add table public.messages;
exception when others then null;
end $$;
