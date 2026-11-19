-- Orbyt update 38: email log
-- Every email the portal sends is already recorded in email_log as "queued". This checks Resend's reply every
-- 5 minutes and marks each one sent or failed (with the reason), so the Email log on your dashboard is accurate.
-- Safe to run more than once.

alter table public.email_log add column if not exists resend_id text;
alter table public.email_log add column if not exists error text;
create index if not exists email_log_sent on public.email_log (sent_at desc);

create or replace function public.email_log_settle() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if to_regclass('net._http_response') is null then return; end if;
  execute $q$
    update public.email_log l set
      status    = case when r.status_code between 200 and 299 then 'sent'
                       when r.status_code is null then 'failed'
                       else 'failed' end,
      resend_id = case when r.status_code between 200 and 299 then (case when r.content ~ '^\s*\{' then r.content::jsonb ->> 'id' end) end,
      error     = case when r.status_code between 200 and 299 then null
                       else left(coalesce(case when r.content ~ '^\s*\{' then nullif(r.content::jsonb ->> 'message', '') end, r.error_msg, 'HTTP ' || r.status_code::text), 300) end
    from net._http_response r
    where r.id = l.request_id and l.status = 'queued'
  $q$;
  -- pg_net keeps replies for a few hours; anything older with no reply is unknown
  update public.email_log set status = 'no reply' where status = 'queued' and sent_at < now() - interval '1 day';
exception when others then
  raise warning 'email log check skipped: %', sqlerrm;
end $$;
revoke execute on function public.email_log_settle() from public, anon, authenticated;

do $$ begin
  begin perform cron.unschedule('orbyt-email-log'); exception when others then null; end;
  perform cron.schedule('orbyt-email-log', '*/5 * * * *', 'select public.email_log_settle()');
exception when others then
  raise notice 'Turn on pg_cron to check email results automatically: %', sqlerrm;
end $$;

select public.email_log_settle();
notify pgrst, 'reload schema';
