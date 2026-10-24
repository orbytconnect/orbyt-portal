-- Run once, after you've signed up in the portal as ashleigh@orbytconnect.com.
-- Makes that account the Orbyt admin. It should say "UPDATE 1".
update public.profiles
   set role = 'admin', status = 'active', approved_at = now()
 where email = 'ashleigh@orbytconnect.com';
