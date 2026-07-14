-- =============================================================================
-- Supabase Auth + Row Level Security — demo schema
--
-- ORDER OF OPERATIONS (this matters):
--   1. Create the two demo users FIRST, in the Supabase dashboard:
--        Authentication -> Users -> Add user  (tick "Auto Confirm User")
--          admin@demo.test   /  demo-admin-2026
--          rep@demo.test     /  demo-rep-2026
--   2. Turn OFF public signups:
--        Authentication -> Sign In / Providers -> "Allow new users to sign up"
--   3. Then paste this whole file into the SQL Editor and run it.
--
-- The seed block at the bottom looks the users up by email, so it will fail
-- loudly (rather than silently seeding orphan rows) if step 1 was skipped.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Clean slate (safe to re-run this file)
-- -----------------------------------------------------------------------------
drop table if exists public.activity_log     cascade;
drop table if exists public.quote_items      cascade;
drop table if exists public.quotes           cascade;
drop table if exists public.customers        cascade;
drop table if exists public.profiles         cascade;
drop table if exists public.unprotected_demo cascade;
drop function if exists public.is_admin()    cascade;


-- -----------------------------------------------------------------------------
-- 1. profiles — one row per auth user, holds the role
-- -----------------------------------------------------------------------------
create table public.profiles (
  id         uuid primary key references auth.users (id) on delete cascade,
  full_name  text not null,
  role       text not null check (role in ('admin', 'rep')),
  created_at timestamptz not null default now()
);


-- -----------------------------------------------------------------------------
-- 2. is_admin() — role lookup as a SECURITY DEFINER function
--
-- Why this exists, and why it is not an inline subquery:
--
-- The obvious way to check "is this user an admin?" inside a policy is
--     exists (select 1 from profiles where id = auth.uid() and role = 'admin')
-- but the moment you use that inside a policy ON profiles, Postgres has to
-- evaluate profiles' own policy to answer it, which evaluates the subquery
-- again -> infinite recursion, and every query on the table errors out.
--
-- SECURITY DEFINER makes the function run as its owner, which bypasses RLS on
-- the tables it reads. The recursion never starts. `set search_path = ''` and
-- fully-qualified table names stop the function being hijacked by a rogue
-- search_path.
-- -----------------------------------------------------------------------------
create function public.is_admin()
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and role = 'admin'
  );
$$;


-- -----------------------------------------------------------------------------
-- 3. customers — shared reference data
--     Read: every logged-in staff member.  Write: admin only.
-- -----------------------------------------------------------------------------
create table public.customers (
  id         bigint generated always as identity primary key,
  name       text not null,
  suburb     text not null,
  created_at timestamptz not null default now()
);


-- -----------------------------------------------------------------------------
-- 4. quotes — owned rows
--     A rep sees only their own.  An admin sees all of them.
-- -----------------------------------------------------------------------------
create table public.quotes (
  id           bigint generated always as identity primary key,
  customer_id  bigint not null references public.customers (id) on delete cascade,
  owner_id     uuid   not null references auth.users (id) on delete cascade,
  title        text   not null,
  amount_cents integer not null check (amount_cents >= 0),
  status       text   not null default 'draft' check (status in ('draft', 'sent', 'won', 'lost')),
  created_at   timestamptz not null default now()
);
create index quotes_owner_id_idx on public.quotes (owner_id);


-- -----------------------------------------------------------------------------
-- 5. quote_items — child rows; visibility inherited from the parent quote
-- -----------------------------------------------------------------------------
create table public.quote_items (
  id           bigint generated always as identity primary key,
  quote_id     bigint not null references public.quotes (id) on delete cascade,
  description  text not null,
  amount_cents integer not null check (amount_cents >= 0)
);
create index quote_items_quote_id_idx on public.quote_items (quote_id);


-- -----------------------------------------------------------------------------
-- 6. activity_log — append-only: any staff member can write, only admin reads
-- -----------------------------------------------------------------------------
create table public.activity_log (
  id         bigint generated always as identity primary key,
  actor_id   uuid not null references auth.users (id) on delete cascade,
  action     text not null,
  created_at timestamptz not null default now()
);


-- -----------------------------------------------------------------------------
-- 7. unprotected_demo — DELIBERATELY LEFT WITHOUT RLS
--
-- This is the failure case, on display. RLS is never enabled on this table, so
-- anyone holding the anon key (which ships inside the HTML, in plain sight) can
-- read every row — no login required. This is what "we put it behind a login"
-- protects you from: nothing at all.
-- -----------------------------------------------------------------------------
create table public.unprotected_demo (
  id          bigint generated always as identity primary key,
  secret_note text not null
);


-- =============================================================================
-- ROW LEVEL SECURITY
--
-- Enabling RLS with no policies denies everyone. A table with RLS never enabled
-- allows everyone. Both facts matter; only one of them is a disaster.
-- =============================================================================

alter table public.profiles     enable row level security;
alter table public.customers    enable row level security;
alter table public.quotes       enable row level security;
alter table public.quote_items  enable row level security;
alter table public.activity_log enable row level security;
-- public.unprotected_demo: intentionally NOT enabled. See above.


-- profiles: you can read yourself; an admin can read everyone.
create policy "profiles: read own, admin reads all"
  on public.profiles for select
  to authenticated
  using (id = auth.uid() or public.is_admin());


-- customers: USING vs WITH CHECK, side by side.
--   USING      filters which existing rows you may see / act on.
--   WITH CHECK validates the rows you are trying to create or leave behind.
create policy "customers: all staff can read"
  on public.customers for select
  to authenticated
  using (true);

create policy "customers: only admin can create"
  on public.customers for insert
  to authenticated
  with check (public.is_admin());

create policy "customers: only admin can update"
  on public.customers for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());


-- quotes: ownership. This is the policy the demo puts on screen.
create policy "quotes: rep reads own, admin reads all"
  on public.quotes for select
  to authenticated
  using (owner_id = auth.uid() or public.is_admin());

-- WITH CHECK on insert stops a rep creating a quote in someone else's name.
create policy "quotes: staff create their own"
  on public.quotes for insert
  to authenticated
  with check (owner_id = auth.uid());

create policy "quotes: rep updates own, admin updates all"
  on public.quotes for update
  to authenticated
  using  (owner_id = auth.uid() or public.is_admin())
  with check (owner_id = auth.uid() or public.is_admin());

create policy "quotes: only admin deletes"
  on public.quotes for delete
  to authenticated
  using (public.is_admin());


-- quote_items: policies compose. A child row is visible only if its parent is.
create policy "quote_items: visible if parent quote is visible"
  on public.quote_items for select
  to authenticated
  using (
    exists (
      select 1
      from public.quotes q
      where q.id = quote_id
        and (q.owner_id = auth.uid() or public.is_admin())
    )
  );


-- activity_log: write without read. Anyone can append as themselves; only an
-- admin can look at the log. There is no SELECT policy for reps, so for a rep
-- the table simply appears empty — it does not error.
create policy "activity_log: staff append as themselves"
  on public.activity_log for insert
  to authenticated
  with check (actor_id = auth.uid());

create policy "activity_log: only admin can read"
  on public.activity_log for select
  to authenticated
  using (public.is_admin());


-- =============================================================================
-- GRANTS
-- Supabase's default privileges usually cover this, but being explicit means
-- this file runs correctly on any project, not just a fresh one.
-- =============================================================================
grant usage on schema public to anon, authenticated;

grant select                         on public.profiles     to authenticated;
grant select, insert, update         on public.customers    to authenticated;
grant select, insert, update, delete on public.quotes       to authenticated;
grant select                         on public.quote_items  to authenticated;
grant select, insert                 on public.activity_log to authenticated;

-- and the cautionary tale: readable by anon, because nothing is stopping it.
grant select on public.unprotected_demo to anon, authenticated;


-- =============================================================================
-- SEED DATA
-- Looks the demo users up by email. If you skipped the "create users" step,
-- this raises instead of quietly seeding rows that point nowhere.
-- =============================================================================
do $$
declare
  admin_id uuid;
  rep_id   uuid;
  cust_a   bigint;
  cust_b   bigint;
  cust_c   bigint;
  q_id     bigint;
begin
  select id into admin_id from auth.users where email = 'admin@demo.test';
  select id into rep_id   from auth.users where email = 'rep@demo.test';

  if admin_id is null or rep_id is null then
    raise exception
      'Create admin@demo.test and rep@demo.test in Authentication -> Users first (tick Auto Confirm User), then re-run this file.';
  end if;

  insert into public.profiles (id, full_name, role) values
    (admin_id, 'Dana Okafor (Operations)', 'admin'),
    (rep_id,   'Sam Reyes (Sales Rep)',    'rep');

  insert into public.customers (name, suburb) values
    ('Northbridge Motors',   'Northbridge')  returning id into cust_a;
  insert into public.customers (name, suburb) values
    ('Harbourview Cafe',     'Balmain')      returning id into cust_b;
  insert into public.customers (name, suburb) values
    ('Kirribilli Dental',    'Kirribilli')   returning id into cust_c;

  -- Three quotes belong to the rep. Nine belong to the admin.
  -- Same query, two logins: 3 rows vs 12. That is the whole demonstration.
  insert into public.quotes (customer_id, owner_id, title, amount_cents, status) values
    (cust_a, rep_id, 'Service department signage',        185000, 'sent'),
    (cust_b, rep_id, 'Fit-out — front counter',           420000, 'draft'),
    (cust_c, rep_id, 'Reception refresh',                  96000, 'won');

  insert into public.quotes (customer_id, owner_id, title, amount_cents, status) values
    (cust_a, admin_id, 'Fleet livery — 12 vehicles',      780000, 'sent'),
    (cust_a, admin_id, 'Showroom lighting upgrade',       310000, 'won'),
    (cust_a, admin_id, 'Annual maintenance retainer',     240000, 'draft'),
    (cust_b, admin_id, 'Outdoor seating canopy',          155000, 'lost'),
    (cust_b, admin_id, 'Kitchen exhaust replacement',     395000, 'sent'),
    (cust_b, admin_id, 'Menu boards — 4 sites',            88000, 'won'),
    (cust_c, admin_id, 'Surgery two build-out',          1250000, 'draft'),
    (cust_c, admin_id, 'Sterilisation bench',             205000, 'sent'),
    (cust_c, admin_id, 'Waiting room joinery',            167000, 'won');

  -- Line items hang off the rep's first quote, to show inherited visibility.
  select id into q_id from public.quotes
    where owner_id = rep_id and title = 'Service department signage';

  insert into public.quote_items (quote_id, description, amount_cents) values
    (q_id, 'Illuminated fascia sign',  120000),
    (q_id, 'Directional bollards x4',   45000),
    (q_id, 'Install and certification',  20000);

  insert into public.activity_log (actor_id, action) values
    (rep_id,   'Sent quote "Service department signage" to Northbridge Motors'),
    (admin_id, 'Marked "Showroom lighting upgrade" as won');

  insert into public.unprotected_demo (secret_note) values
    ('Payroll run 2026-07-15: total $184,320.00'),
    ('Bank account ****4471, BSB 062-XXX'),
    ('Nobody is logged in and you are reading this. That is the point.');
end;
$$;
