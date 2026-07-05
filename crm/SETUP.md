# Launch checklist — cloud CRM on Supabase

Everything in this `cloud/` folder is what you deploy. Total setup is about 15 minutes,
and only steps you can do yourself — no credentials ever go through anyone else.

## 1 · Set up the database (5 min)

1. Open your Supabase project → **SQL Editor** → **New query**.
2. Open `supabase-schema.sql` from this folder, copy ALL of it, paste, click **Run**.
   You should see "Success. No rows returned." It is safe to run twice.
3. Check the admin email: the schema sets **prkrfwlr@gmail.com** as the agency admin.
   If you want a different admin email, edit it in the `agency_settings` insert near the
   top of the SQL file *before* running (or later in Table Editor → agency_settings).

Optional but recommended for smoother client signups:
**Authentication → Sign In / Up → Email** — if "Confirm email" is ON, clients must click a
confirmation link before first sign-in. Turn it OFF if you want instant signups.

## 2 · Connect the apps (2 min)

1. In Supabase: **Project Settings → API** (or "Data API").
2. Copy the **Project URL** and the **anon / public** key.
3. Open `config.js` in this folder with any text editor and paste both values.
   (The anon key is designed to be public — row-level security in the database is
   what protects the data, and it's already configured by the schema.)

## 3 · Deploy the folder (5 min)

Deploy this `cloud/` folder to any static host. Two good free options:

**GitHub Pages**
1. Create a repository (private repos work with Pages on paid plans; public otherwise).
2. Upload the contents of `cloud/` (index.html, agency.html, config.js — the .sql and
   .md files are harmless to include).
3. Settings → Pages → deploy from branch → root. Your URLs become:
   - `https://YOURNAME.github.io/REPO/` → the client portal
   - `https://YOURNAME.github.io/REPO/agency.html` → your CRM

**Vercel**
1. Create a free account at vercel.com, install nothing — use "Add New → Project →
   Deploy" and drag the `cloud/` folder in (or connect the GitHub repo).
2. Same URL shape: `/` is the portal, `/agency.html` is your CRM.

Then in Supabase: **Authentication → URL Configuration** → set **Site URL** to your
deployed URL (this makes email-confirmation links land in the right place).

## 4 · Create your admin account (1 min)

1. Open `https://…/agency.html` → **Create the admin account** → sign up with the
   agency email from step 1. The database recognizes it and grants agency access.
2. You land in your CRM. Go to **Settings → Import / migrate** and load your latest
   backup from the local app (open the old `CRM/agency.html`, Settings → Export full
   backup) — every client, lead, task and invoice moves to the cloud with IDs intact.

## 5 · Give a client access (1 min per client)

1. In your CRM, open the client → **Edit client** → set their **Login email**.
2. Send them the portal link (shown on the client's **Portal access** tab).
3. They click **Create your account** using that same email — they're automatically
   linked to their business and see only their own data.

If a client signs up *before* you set their email, no problem: set it afterward and the
link happens automatically; they just reload.

## Who sees what

| Data | You | Client |
| --- | --- | --- |
| Their leads, jobs, quotes | full control | full control |
| Marketing results (ads) | full control | read-only |
| Retainer, notes, tasks, billing, other clients | full control | never visible |

Enforced by Postgres row-level security — not by the app — so even someone poking at
the API with the public key can't cross those lines.

## Day-2 notes

- **Backups:** Settings → Download backup in your CRM gives you the same JSON as
  before. Supabase free tier also keeps daily database backups.
- **Custom domain:** both GitHub Pages and Vercel support one for free; nothing in the
  app needs to change.
- **The old local apps** (`CRM/agency.html`, `CRM/portal.html`) still work offline and
  are now your cold-storage fallback. Don't run both as source of truth — after
  migrating, live in the cloud version.
