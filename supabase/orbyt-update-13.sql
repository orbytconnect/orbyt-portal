-- Orbyt update 13: home team cards for buyers
-- 1. Agents make a printable "home team" card for buyer clients: their picked vendors (names, ratings and
--    specialties only, never contact details) and a QR code to their own request page.
-- 2. The request page (portal.orbytconnect.com/r/<name>) needs no login. A client says what they need, and it
--    lands as a buyer project in the agent's portal, with an email to the agent and to Ashleigh.
-- 3. Agents can add their own logo, so the card and the request page are co-branded.
-- 4. Projects can hold the client's email and phone (private to the agent, people they share with, and Ashleigh).
-- Safe to run more than once.

alter table public.project_private add column if not exists client_email text;
alter table public.project_private add column if not exists client_phone text;

-- one card per agent: the short link name and what's on the card
create table if not exists public.home_cards (
  agent_id    uuid primary key references public.profiles (id) on delete cascade,
  slug        text not null unique check (slug ~ '^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$'),
  settings    jsonb not null default '{}',
  logo        text,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
alter table public.home_cards enable row level security;
drop policy if exists home_cards_own on public.home_cards;
create policy home_cards_own on public.home_cards for select to authenticated
  using (agent_id = auth.uid() or public.is_admin());
drop policy if exists home_cards_admin on public.home_cards;
create policy home_cards_admin on public.home_cards for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
revoke all on public.home_cards from anon;
grant select on public.home_cards to authenticated;

-- every request that comes in from a card (also used to slow down anyone sending too many)
create table if not exists public.home_card_requests (
  id           uuid primary key default gen_random_uuid(),
  agent_id     uuid references public.profiles (id) on delete cascade,
  project_id   uuid references public.projects (id) on delete set null,
  client_name  text,
  client_email text,
  client_phone text,
  ip           text,
  created_at   timestamptz not null default now()
);
alter table public.home_card_requests enable row level security;
drop policy if exists home_card_requests_read on public.home_card_requests;
create policy home_card_requests_read on public.home_card_requests for select to authenticated
  using (agent_id = auth.uid() or public.is_admin());
revoke all on public.home_card_requests from anon;
grant select on public.home_card_requests to authenticated;
alter table public.home_cards add column if not exists logo text;
alter table public.home_cards drop constraint if exists home_cards_logo_ok;
alter table public.home_cards add constraint home_cards_logo_ok
  check (logo is null or (logo ~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$' and length(logo) <= 400000));
create index if not exists home_card_requests_ip on public.home_card_requests (ip, created_at);
create index if not exists home_card_requests_agent on public.home_card_requests (agent_id, created_at);

-- save the card (agents save their own). p_logo: leave out to keep the logo, '' to remove it, or a small image. The short link name is picked the first time: first name,
-- then first and last name, then a number, whichever is free.
drop function if exists public.home_card_save(jsonb);
create or replace function public.home_card_save(p_settings jsonb, p_logo text default null)
returns text language plpgsql security definer set search_path = '' as $$
declare me public.profiles%rowtype; s text; base text; full_base text; n int := 1;
begin
  select * into me from public.profiles where id = auth.uid();
  if me.id is null or me.role <> 'agent' or me.status <> 'active' then
    raise exception 'Only active agents can make a home team card.';
  end if;
  if p_settings is null or jsonb_typeof(p_settings) <> 'object' or length(p_settings::text) > 8000 then
    raise exception 'That card is too large to save.';
  end if;
  select slug into s from public.home_cards where agent_id = me.id;
  if s is null then
    full_base := trim(both '-' from regexp_replace(lower(coalesce(me.full_name, '')), '[^a-z0-9]+', '-', 'g'));
    base := split_part(full_base, '-', 1);
    if length(base) < 2 then base := 'agent'; end if;
    if length(full_base) < 2 then full_base := base; end if;
    full_base := left(full_base, 34);
    s := base;
    if exists (select 1 from public.home_cards where slug = s) then s := full_base; end if;
    while exists (select 1 from public.home_cards where slug = s) loop
      n := n + 1; s := full_base || '-' || n;
    end loop;
  end if;
  if p_logo is not null and p_logo <> '' and (p_logo !~ '^data:image/(png|jpeg|webp);base64,' or length(p_logo) > 400000) then
    raise exception 'That logo is too large. Try a PNG or JPG under 250 KB.';
  end if;
  insert into public.home_cards (agent_id, slug, settings, logo) values (me.id, s, p_settings, nullif(p_logo, ''))
  on conflict (agent_id) do update set settings = excluded.settings, updated_at = now(),
    logo = case when p_logo is null then public.home_cards.logo else nullif(p_logo, '') end;
  return s;
end $$;
revoke execute on function public.home_card_save(jsonb, text) from public, anon;
grant execute on function public.home_card_save(jsonb, text) to authenticated;

-- what the request page shows (no login): the agent's name and brokerage, and the services on their card.
-- Vendor names only, never vendor contact details.
create or replace function public.home_card_get(p_slug text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'agent', p.full_name, 'brokerage', p.brokerage, 'phone', p.phone, 'logo', c.logo,
    'priority', coalesce((c.settings ->> 'priority')::boolean, true),
    'featured', coalesce((select jsonb_agg(jsonb_build_object('c', f ->> 'c', 'name', v.name) order by o)
                            from jsonb_array_elements(case when jsonb_typeof(c.settings -> 'featured') = 'array' then c.settings -> 'featured' else '[]'::jsonb end)
                                 with ordinality as x(f, o)
                            left join public.vendors v on v.id::text = (f ->> 'v')
                           where coalesce(f ->> 'c', '') <> ''), '[]'::jsonb),
    'also', case when jsonb_typeof(c.settings -> 'also') = 'array' then c.settings -> 'also' else '[]'::jsonb end)
    from public.home_cards c join public.profiles p on p.id = c.agent_id
   where c.slug = lower(trim(coalesce(p_slug, ''))) and c.active and p.role = 'agent' and p.status = 'active'
$$;
revoke execute on function public.home_card_get(text) from public;
grant execute on function public.home_card_get(text) to anon, authenticated;

-- a client sends a request from the card's page
create or replace function public.home_card_request(p_slug text, p_name text, p_email text, p_phone text, p_address text,
                                                    p_services text[], p_when text, p_notes text, p_company text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  c     public.home_cards%rowtype;
  a     public.profiles%rowtype;
  v_ip  text := public.request_ip();
  nm    text := left(trim(coalesce(p_name, '')), 120);
  em    text := lower(left(trim(coalesce(p_email, '')), 200));
  ph    text := left(trim(coalesce(p_phone, '')), 40);
  addr  text := left(trim(coalesce(p_address, '')), 200);
  svcs  text[];
  picks text := '';
  f     jsonb;
  vname text;
  body  text;
  pid   uuid;
begin
  select * into c from public.home_cards where slug = lower(trim(coalesce(p_slug, ''))) and active;
  if c.agent_id is not null then select * into a from public.profiles where id = c.agent_id; end if;
  if a.id is null or a.role <> 'agent' or a.status <> 'active' then
    raise exception 'This page isn''t active. Reach out to your agent directly.';
  end if;
  -- the hidden "company" box is only ever filled in by bots: say thanks and do nothing
  if coalesce(trim(p_company), '') <> '' then return; end if;
  if nm = '' then raise exception 'Add your name.'; end if;
  if em = '' and ph = '' then raise exception 'Add an email or phone number so we can reach you.'; end if;
  if em <> '' and em !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then raise exception 'Check your email address.'; end if;
  if addr = '' then raise exception 'Add the home''s address.'; end if;
  select array_agg(s order by o) into svcs from (
    select left(trim(x), 40) as s, min(n) as o from unnest(coalesce(p_services, '{}'::text[])) with ordinality as u(x, n)
     where trim(coalesce(x, '')) <> '' group by 1 order by 2 limit 12) q;
  if svcs is null then raise exception 'Pick at least one thing you need.'; end if;
  -- slow down anyone sending lots of requests
  if v_ip is not null and (select count(*) from public.home_card_requests r where r.ip = v_ip and created_at > now() - interval '1 hour') >= 5 then
    raise exception 'You''ve sent a few requests already. Give us a little time to reply, or reach out to your agent directly.';
  end if;
  if (select count(*) from public.home_card_requests where agent_id = a.id and created_at > now() - interval '1 day') >= 30 then
    raise exception 'This page has had a lot of requests today. Please reach out to your agent directly.';
  end if;

  -- which pro is on the card for each service asked for
  for f in select * from jsonb_array_elements(case when jsonb_typeof(c.settings -> 'featured') = 'array' then c.settings -> 'featured' else '[]'::jsonb end) loop
    if (f ->> 'c') = any (svcs) then
      select name into vname from public.vendors where id::text = (f ->> 'v');
      if vname is not null then picks := picks || case when picks = '' then '' else ', ' end || (f ->> 'c') || ': ' || vname; end if;
    end if;
  end loop;

  insert into public.projects (agent_id, agent_name, agent_email, agent_phone, brokerage, address, client_type, categories, notes, source, created_by)
  values (a.id, coalesce(a.full_name, a.email), a.email, a.phone, a.brokerage, addr, 'Buyer', svcs,
          nullif(concat_ws(E'\n',
            'Request from ' || nm || ' through ' || coalesce(split_part(a.full_name, ' ', 1), 'the agent') || '''s home team card.',
            case when coalesce(trim(p_when), '') <> '' then 'Timing: ' || left(trim(p_when), 60) end,
            case when picks <> '' then 'On the card: ' || picks end,
            case when coalesce(trim(p_notes), '') <> '' then 'From the client: ' || left(trim(p_notes), 1500) end), ''),
          'Home team card', nm)
  returning id into pid;
  update public.project_private set client_name = nm, client_email = nullif(em, ''), client_phone = nullif(ph, '') where project_id = pid;
  insert into public.home_card_requests (agent_id, project_id, client_name, client_email, client_phone, ip)
  values (a.id, pid, nm, nullif(em, ''), nullif(ph, ''), v_ip);

  body := public.ep('<b>' || public.h(nm) || '</b> needs <b>' || public.h(lower(array_to_string(svcs, ', '))) || '</b> at <b>' || public.h(addr) || '</b>.')
       || case when coalesce(trim(p_when), '') <> '' then public.ep('Timing: ' || public.h(left(trim(p_when), 60))) else '' end
       || case when picks <> '' then public.ep('On the card: ' || public.h(picks)) else '' end
       || case when coalesce(trim(p_notes), '') <> '' then public.ep('<i>' || public.h(left(trim(p_notes), 600)) || '</i>') else '' end
       || public.ep('Reach them at ' || public.h(concat_ws(' · ', nullif(ph, ''), nullif(em, ''))) || '.');
  perform public.orbyt_email(array[a.email], nm || ' asked for ' || lower(array_to_string(svcs, ', ')) || ' from your home team card',
    'Your client sent a request', body
    || public.ep('It''s in your portal as a project. I''ll set up the intros and quotes, and you''ll see them there as they come in.'),
    'Open the portal', 'card_request_agent');
  perform public.orbyt_email(array[public.admin_email()], 'Home team card request: ' || nm || ' (' || coalesce(a.full_name, a.email) || '''s client)',
    'A home team card request needs matching',
    public.ep('From ' || public.h(coalesce(a.full_name, a.email)) || '''s home team card.') || body,
    'Start matching', 'card_request_admin');
end $$;
revoke execute on function public.home_card_request(text, text, text, text, text, text[], text, text, text) from public;
grant execute on function public.home_card_request(text, text, text, text, text, text[], text, text, text) to anon, authenticated;

-- card requests send their own emails, so skip the general "new project" one for them
create or replace function public.projects_notify() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if public.is_admin() or new.source = 'Home team card' then return new; end if;
  perform public.orbyt_email(array[public.admin_email()], 'New project from ' || new.agent_name || ': ' || new.address, 'A new project needs matching',
    public.ep(public.h(new.agent_name) || ' added <b>' || public.h(new.address) || '</b>' || case when coalesce(new.area, '') <> '' then ' in ' || public.h(new.area) else '' end
              || case when new.target_date is not null then ', target date ' || public.date_text(new.target_date) else '' end || '.')
    || public.ep('Needs: ' || public.h(array_to_string(new.categories, ', ')))
    || case when coalesce(new.notes, '') <> '' then public.ep('Notes: ' || public.h(new.notes)) else '' end,
    'Start matching', 'admin_project');
  return new;
exception when others then
  raise warning 'Orbyt project email skipped: %', sqlerrm;
  return new;
end $$;

-- which services the network covers (no vendor names), so the card maker can say which "also on call" services have a pro yet
create or replace function public.network_services() returns text[] language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(distinct s order by s), '{}') from public.vendors v join public.vendor_admin a on a.vendor_id = v.id, unnest(v.services) s
   where a.approved
$$;
revoke execute on function public.network_services() from public, anon;
grant execute on function public.network_services() to authenticated;
