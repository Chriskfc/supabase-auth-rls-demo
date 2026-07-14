# Supabase Auth + RLS Demo — Design

**Date:** 2026-07-14
**Purpose:** A public, linkable proof-of-competence artifact: a live single-file HTML app backed by a real Supabase project, demonstrating Supabase Auth + Row Level Security. Built to answer the Kennyco Upwork requirement ("link to a project or repo that used both"), and reusable for Giftopia and future proposals.

## Goal

A prospective client can, in under a minute:

1. Open a live URL.
2. Log in as a **rep**, see a subset of rows.
3. Log in as an **admin**, see all rows.
4. See that the front-end query never changed — the database enforced it.
5. Read the repo and see the actual policies.

That sequence is the sales pitch. Everything else serves it.

## Non-goals

- Not a product. No signup flow, no billing, no responsive polish beyond "looks professional".
- Not a framework demo. No React, no build step. Single HTML file, `supabase-js` from CDN — deliberately the same shape as the Kennyco apps.
- Not real data. All seed data is fictional.

## Architecture

- **Front end:** one `index.html`, hosted on GitHub Pages from the repo root. Supabase client via CDN. The anon key is committed to the repo in plain sight — that is the point, and the README explains why it is safe.
- **Back end:** one free Supabase project (Sydney region, `ap-southeast-2`). Auth = email/password. Public signups **disabled**. Users created by hand.
- **No server.** Browser talks directly to Supabase. RLS is the only thing standing between the anon key and the data.

## Schema (5 tables — mirrors the Kennyco job's shape)

| Table | Purpose |
|---|---|
| `profiles` | 1:1 with `auth.users`. Holds `full_name`, `role` (`admin` \| `rep`). |
| `customers` | Shared reference data. All staff read; only admin writes. |
| `quotes` | Owned rows. A rep sees only their own; admin sees all. |
| `quote_items` | Child rows. Visibility inherited from the parent quote. |
| `activity_log` | Append-only. Any staff member can insert; only admin can read. |
| `unprotected_demo` | **Sixth table, deliberately RLS-disabled.** Dummy rows. Exists solely to show what a table without RLS looks like to anyone holding the anon key. |

## RLS design (the substance)

Each policy is chosen to demonstrate a distinct concept:

1. **Owner-scoped read** — `quotes`: `using (owner_id = auth.uid() or is_admin())`.
   Demonstrates `auth.uid()` and row ownership.
2. **`using` vs `with check`** — `customers`: all authenticated staff `select`; only admin `insert`/`update`.
   Demonstrates that read-filtering and write-validation are separate clauses. This is the distinction most people fumble.
3. **Role lookup via `security definer` helper** — `is_admin()` is a `security definer` function reading `profiles`, **not** an inline subquery.
   A naive subquery on `profiles` inside a `profiles` policy causes infinite recursion. Avoiding it is the tell that the author has actually done this.
4. **Parent-derived visibility** — `quote_items`: visible only if the parent quote is visible (`exists` against `quotes`).
   Demonstrates that policies compose.
5. **Insert-only** — `activity_log`: `with check (actor_id = auth.uid())` on insert, admin-only `select`.
   Demonstrates write-without-read.
6. **RLS off** — `unprotected_demo`: no RLS, and the demo shows it leaking to any visitor.

## The proof panel

The page has two columns:

- **Left:** the app view (quotes list, customers, "log activity" button).
- **Right:** the proof panel, showing for the current session:
  - the literal JS query being run (`supabase.from('quotes').select('*')`) — identical for both users,
  - the policy SQL currently guarding that table,
  - the row count returned.

Log in as rep → 3 quotes. Log in as admin → 12 quotes. Same query, same file, different result. Below that, the `unprotected_demo` table renders its rows for *anyone*, labelled as the failure case.

## Auth setup

- Public signups **disabled** in the dashboard.
- Two users created by hand, auto-confirmed, credentials published in the README:
  - `rep@demo.test`
  - `admin@demo.test`
- README documents the consequence: with signups disabled and Supabase's built-in email rate-limited, password resets need either manual password setting or a real SMTP sender. (Same decision Kennyco has to make.)

## Deliverables

1. Public GitHub repo: `supabase-auth-rls-demo`.
2. `schema.sql` — tables, policies, helper function, seed data. Copy-paste-runnable by anyone.
3. `index.html` — the app + proof panel.
4. `README.md` — the sales asset. What it proves, the demo logins, a policy walkthrough, and the "the anon key is public by design; RLS is the real protection" explanation.
5. Live GitHub Pages URL.

## Risks

- **The anon key is in a public repo.** Acceptable and intentional: the project holds only fictional data, signups are disabled, and RLS is enforced. The README states this explicitly so no one mistakes it for a mistake.
- **Free-tier projects pause after inactivity.** If the demo is dormant for a stretch, first load may need a wake-up. Note it in the README; unpause before sending a link to a client.
