-- Orbyt update 18b: fix for "Set up push notifications"
-- Supabase blocks a DELETE with no WHERE clause, which stopped the one-time setup. This replaces that one function.
-- Safe to run more than once. Run it after update 18, then click Set up push notifications again.

-- Ashleigh's one-time setup: the browser makes the key pair, the private half goes straight into the Vault
create or replace function public.push_setup(p_public text, p_private text) returns void
language plpgsql security definer set search_path = '' as $$
declare sid uuid;
begin
  if not public.is_admin() then raise exception 'Only Orbyt can set up notifications.'; end if;
  if p_public !~ '^[A-Za-z0-9_-]{80,100}$' or p_private !~ '^[A-Za-z0-9_-]{40,50}$' then raise exception 'Those keys don''t look right.'; end if;
  select id into sid from vault.decrypted_secrets where name = 'vapid_private' limit 1;
  if sid is null then perform vault.create_secret(p_private, 'vapid_private', 'Orbyt push notification signing key');
  else perform vault.update_secret(sid, p_private); end if;
  insert into public.settings (key, value, is_public)
  values ('push', jsonb_build_object('public_key', p_public, 'subject', 'mailto:ashleigh@orbytconnect.com',
                                     'sender', 'https://portal.orbytconnect.com/.netlify/functions/push'), true)
  on conflict (key) do update set value = public.settings.value || excluded.value, is_public = true;
  -- a new key means old subscriptions won't work any more
  delete from public.push_subscriptions where true;
end $$;
revoke execute on function public.push_setup(text, text) from public, anon;
grant execute on function public.push_setup(text, text) to authenticated;
