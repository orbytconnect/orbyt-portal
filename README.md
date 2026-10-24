# Orbyt Portal

The agent and vendor portal for Orbyt, live at https://portal.orbytconnect.com (also reachable at https://orbyt-portal.netlify.app).

## What's here

| Folder | What it holds |
|---|---|
| `site/` | The published portal: `index.html`, the email logo and security headers. Netlify serves this folder. |
| `src/` | The source the page is built from: `orbyt-portal.html` (the screens), `live.js` (the Supabase connection, sign-in, agreements, Agents tab) and `build_live.py`, which combines them into `site/index.html`. |
| `supabase/` | Database scripts. `orbyt-schema.sql` is the full setup; the numbered `orbyt-update-N.sql` files were run in order on the live project. |

## How changes go live

1. Edit files in `src/`, then run `python3 src/build_live.py` to rebuild `site/index.html`.
2. Commit and push to `main`. Netlify publishes it within a minute.
3. If a change needs a database update, add the next numbered `supabase/orbyt-update-N.sql`, and run it in the Supabase SQL Editor before the push goes live.

## Keys

The Supabase publishable key in the code is meant to be public. Never commit the Supabase secret key or any Resend key. The Resend key lives in Supabase (SMTP settings and Vault).

The step-by-step runbook for running the portal is the "Orbyt Portal Runbook" Google Doc.
