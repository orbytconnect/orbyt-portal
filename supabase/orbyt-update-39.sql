-- Orbyt update 39: email delivery and clicks from Resend
-- Resend tells the portal when each email is delivered, bounces, is marked as spam, or a link in it is clicked.
-- These show in the Email log on your dashboard. Needs update 38 first. Safe to run more than once.

alter table public.email_log add column if not exists delivered_at timestamptz;
alter table public.email_log add column if not exists clicked_at timestamptz;
alter table public.email_log add column if not exists clicks int not null default 0;
alter table public.email_log add column if not exists opened_at timestamptz;
alter table public.email_log add column if not exists bounced_at timestamptz;
alter table public.email_log add column if not exists complained_at timestamptz;
create index if not exists email_log_resend on public.email_log (resend_id);

-- called by the Netlify resend-webhook function, with the same shared secret as card payments
create or replace function public.email_event_apply(p_secret text, p_event jsonb) returns text
language plpgsql security definer set search_path = '' as $$
declare k text; eid text := p_event -> 'data' ->> 'email_id'; t text := p_event ->> 'type';
  at timestamptz := coalesce((p_event ->> 'created_at')::timestamptz, now()); n int;
begin
  select decrypted_secret into k from vault.decrypted_secrets where name = 'billing_secret' limit 1;
  if k is null or p_secret is null or p_secret <> k then raise exception 'Not allowed'; end if;
  if eid is null then return 'no email id'; end if;
  -- the email may still be waiting for its sent/failed check
  if not exists (select 1 from public.email_log where resend_id = eid) then perform public.email_log_settle(); end if;
  update public.email_log set
    status        = case t when 'email.bounced' then 'bounced' when 'email.complained' then 'spam report'
                           when 'email.delivered' then case when status in ('queued', 'sent', 'delayed') then 'delivered' else status end
                           when 'email.delivery_delayed' then case when status in ('queued', 'sent') then 'delayed' else status end
                           else status end,
    delivered_at  = case when t = 'email.delivered' then coalesce(delivered_at, at) else delivered_at end,
    bounced_at    = case when t = 'email.bounced' then coalesce(bounced_at, at) else bounced_at end,
    complained_at = case when t = 'email.complained' then coalesce(complained_at, at) else complained_at end,
    opened_at     = case when t = 'email.opened' then coalesce(opened_at, at) else opened_at end,
    clicked_at    = case when t = 'email.clicked' then coalesce(clicked_at, at) else clicked_at end,
    clicks        = clicks + case when t = 'email.clicked' then 1 else 0 end,
    error         = case when t = 'email.bounced' then left(coalesce(p_event -> 'data' -> 'bounce' ->> 'message', 'Bounced'), 300) else error end
  where resend_id = eid;
  get diagnostics n = row_count;
  return case when n > 0 then 'recorded' else 'no matching email' end;
end $$;
revoke execute on function public.email_event_apply(text, jsonb) from public;
grant execute on function public.email_event_apply(text, jsonb) to anon, authenticated;

notify pgrst, 'reload schema';
