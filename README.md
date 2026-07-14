# Supabase Auth + Row Level Security — a working demonstration

**Live demo:** _(link goes here once Pages is up)_

A single HTML file, a free Supabase project, five tables under row level security, and two staff logins.
Sign in as the sales rep, then sign in as the operations admin. **The same query returns different rows.**
Nothing in the front end filters anything — Postgres decides what leaves the database.

| Account | Password | What they get |
|---|---|---|
| `rep@demo.test` | `demo-rep-2026` | 3 of the 12 quotes — their own. Can write to the activity log but not read it. |
| `admin@demo.test` | `demo-admin-2026` | All 12 quotes. Can read the activity log. Can edit customers. |

Public signup is **disabled** on this project. Both accounts were created by hand, which is how a real internal
tool is run.

## What it demonstrates

**The anon key is public, and that is fine.** It ships inside `index.html` in plain sight. Anyone can read it.
That is safe *only* because row level security is enforced on every table that holds anything real —
the login screen is not what protects the data, the policies are. The `service_role` key is the one that must
never appear in a browser: it bypasses every policy in this repo.

**Row filtering happens in the database, not the browser.** The app runs exactly one data query:

```js
await supabase.from('quotes').select('*, customers(name), quote_items(*)').order('created_at')
```

No `where owner_id = …`. No client-side filter. The rep receives three rows; the admin receives twelve.
Open the network tab and check — the rep's response does not *contain* the other nine rows. They were never sent.

**Reads and writes are checked separately.** `USING` decides which rows you may see. `WITH CHECK` decides which
rows you may leave behind. The demo has a button that tries to write an activity-log entry in someone else's
name; the database refuses it, and the raw Postgres error is printed on screen.

**A table without RLS leaks to everyone.** One table in this project (`unprotected_demo`) was deliberately left
without it. The page renders its contents to visitors who are not signed in at all. That is the accident the
other five tables are protected from — and it is the single most common way Supabase projects lose data.

**Role checks need a `security definer` function, not a subquery.** Checking "is this user an admin?" with an
inline `select … from profiles` inside a policy *on* `profiles` sends Postgres into infinite recursion. The
`is_admin()` helper in [`schema.sql`](schema.sql) avoids it, with `set search_path = ''` so it cannot be hijacked.

## The tables

| Table | Policy | Concept shown |
|---|---|---|
| `profiles` | read own; admin reads all | `auth.uid()`, and the recursion trap |
| `customers` | all staff read; admin writes | `USING` vs `WITH CHECK` |
| `quotes` | rep reads own; admin reads all | row ownership — the headline demo |
| `quote_items` | visible if the parent quote is | policies composing |
| `activity_log` | anyone appends as themselves; admin reads | write without read |
| `unprotected_demo` | **none — RLS never enabled** | the failure case |

## Run it yourself

1. Create a free Supabase project (this one is in Sydney, `ap-southeast-2`).
2. **Authentication → Users → Add user**, twice, ticking *Auto Confirm User*:
   `admin@demo.test` / `demo-admin-2026` and `rep@demo.test` / `demo-rep-2026`.
3. **Authentication → Sign In / Providers →** turn *Allow new users to sign up* **off**.
4. Paste [`schema.sql`](schema.sql) into the SQL editor and run it. It creates the tables, the policies and the
   seed data, and it will refuse to run if you skipped step 2.
5. Put your project URL and anon key at the top of the `<script>` block in `index.html`, and serve the file
   from anywhere static.

## Two things worth knowing before you build on this

**Password resets.** With signups disabled and Supabase's built-in email heavily rate-limited, a staff member who
forgets their password has no self-serve way back in. Either an admin sets passwords manually, or the project
needs a real SMTP sender attached. Decide which before you hand the thing over, not after.

**Free projects pause.** A free-tier project pauses after a stretch of inactivity and gets no backups. Fine for a
demo or a light internal tool; not fine for a system a business depends on.

---

All data here is fictional. Built by [Chris](https://thrivecodelabs.com) as a reference implementation.
