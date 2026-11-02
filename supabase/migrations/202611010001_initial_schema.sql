-- MyLedger initial schema. All monetary amounts are decimal INR values.
create extension if not exists pgcrypto;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  timezone text not null default 'Asia/Kolkata',
  currency char(3) not null default 'INR',
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.accounts (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
  name text not null, account_type text not null check (account_type in ('cash','savings','salary','current','wallet','credit_card','other_asset','other_liability')),
  institution text, opening_balance numeric(19,2) not null default 0, currency char(3) not null default 'INR',
  is_archived boolean not null default false, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique (id, user_id)
);
create table public.categories (
  id uuid primary key default gen_random_uuid(), user_id uuid references auth.users(id) on delete cascade,
  name text not null, kind text not null check (kind in ('income','expense')), parent_id uuid references public.categories(id) on delete set null,
  color text, created_at timestamptz not null default now(), unique (user_id, kind, name), unique (id, user_id)
);
create table public.transactions (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
  transaction_type text not null check (transaction_type in ('income','expense','transfer','refund','credit_card_purchase','credit_card_payment')),
  amount numeric(19,2) not null check (amount > 0), currency char(3) not null default 'INR', category_id uuid references public.categories(id) on delete set null,
  account_id uuid not null, destination_account_id uuid, merchant text, transaction_date date not null, transaction_time time,
  payment_method text, description text, notes text, tags text[] not null default '{}', receipt_path text,
  linked_transaction_id uuid references public.transactions(id) on delete set null, status text not null default 'posted' check (status in ('posted','voided')),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  foreign key (account_id, user_id) references public.accounts(id, user_id),
  foreign key (destination_account_id, user_id) references public.accounts(id, user_id),
  foreign key (category_id, user_id) references public.categories(id, user_id),
  check (transaction_type <> 'transfer' or (destination_account_id is not null and destination_account_id <> account_id)),
  unique (id, user_id)
);
create table public.transaction_splits (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
  transaction_id uuid not null, category_id uuid references public.categories(id) on delete set null,
  amount numeric(19,2) not null check (amount > 0), note text,
  foreign key (transaction_id, user_id) references public.transactions(id, user_id) on delete cascade,
  foreign key (category_id, user_id) references public.categories(id, user_id)
);
-- Signed postings form the account ledger. A transfer has equal and opposite postings.
create table public.account_postings (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
  transaction_id uuid not null, account_id uuid not null, amount numeric(19,2) not null check (amount <> 0), posted_at timestamptz not null,
  foreign key (transaction_id, user_id) references public.transactions(id, user_id) on delete cascade,
  foreign key (account_id, user_id) references public.accounts(id, user_id)
);
create table public.budgets (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
  category_id uuid, name text not null, amount numeric(19,2) not null check (amount > 0),
  period text not null default 'monthly' check (period in ('weekly','monthly','yearly','custom')), starts_on date not null, ends_on date,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), check (ends_on is null or ends_on >= starts_on),
  foreign key (category_id, user_id) references public.categories(id, user_id) on delete cascade
);
create table public.recurring_transactions (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
  transaction_type text not null check (transaction_type in ('income','expense')), amount numeric(19,2) not null check (amount > 0),
  account_id uuid not null, category_id uuid references public.categories(id) on delete set null, merchant text, cadence text not null check (cadence in ('weekly','monthly','quarterly','yearly')),
  next_date date not null, is_active boolean not null default true, created_at timestamptz not null default now(),
  foreign key (account_id, user_id) references public.accounts(id, user_id)
);
create table public.recurring_occurrences (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
  recurring_id uuid not null references public.recurring_transactions(id) on delete cascade, transaction_id uuid references public.transactions(id) on delete set null,
  due_date date not null, status text not null default 'upcoming' check (status in ('upcoming','paid','skipped')), unique (recurring_id, due_date)
);
create table public.bills (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
  name text not null, amount numeric(19,2), due_date date not null, cadence text check (cadence in ('once','weekly','monthly','quarterly','yearly')),
  account_id uuid, is_paid boolean not null default false, created_at timestamptz not null default now(),
  foreign key (account_id, user_id) references public.accounts(id, user_id)
);
create table public.financial_goals (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
  name text not null, target_amount numeric(19,2) not null check (target_amount > 0), target_date date, created_at timestamptz not null default now()
);
create table public.goal_contributions (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
  goal_id uuid not null references public.financial_goals(id) on delete cascade, amount numeric(19,2) not null check (amount > 0), contributed_at date not null default current_date,
  account_id uuid, transaction_id uuid references public.transactions(id) on delete set null,
  foreign key (account_id, user_id) references public.accounts(id, user_id)
);
create table public.attachments (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
  transaction_id uuid references public.transactions(id) on delete cascade, storage_path text not null, file_name text not null,
  content_type text not null, size_bytes bigint not null check (size_bytes > 0), created_at timestamptz not null default now()
);
create table public.notifications (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null, message text not null, read_at timestamptz, created_at timestamptz not null default now()
);
create table public.audit_logs (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
  entity_type text not null, entity_id uuid not null, action text not null, before_data jsonb, after_data jsonb, created_at timestamptz not null default now()
);
create table public.user_settings (
  user_id uuid primary key references auth.users(id) on delete cascade, currency char(3) not null default 'INR', timezone text not null default 'Asia/Kolkata',
  theme text not null default 'system' check (theme in ('light','dark','system')), week_starts_on smallint not null default 1 check (week_starts_on between 0 and 6), updated_at timestamptz not null default now()
);

create index transactions_owner_date_idx on public.transactions(user_id, transaction_date desc);
create index transactions_owner_type_date_idx on public.transactions(user_id, transaction_type, transaction_date desc);
create index postings_owner_account_date_idx on public.account_postings(user_id, account_id, posted_at desc);
create index splits_owner_transaction_idx on public.transaction_splits(user_id, transaction_id);
create index budgets_owner_period_idx on public.budgets(user_id, starts_on, ends_on);
create index bills_owner_due_idx on public.bills(user_id, due_date) where not is_paid;
create index goals_owner_idx on public.financial_goals(user_id);
create index contributions_owner_goal_date_idx on public.goal_contributions(user_id, goal_id, contributed_at desc);
create index notifications_owner_created_idx on public.notifications(user_id, created_at desc);
create index audit_owner_entity_idx on public.audit_logs(user_id, entity_type, entity_id, created_at desc);

-- Every user-owned table enforces isolation even when accessed with the public client key.
do $$ declare tbl text; begin
  foreach tbl in array array['profiles','accounts','categories','transactions','transaction_splits','account_postings','budgets','recurring_transactions','recurring_occurrences','bills','financial_goals','goal_contributions','attachments','notifications','audit_logs','user_settings'] loop
    execute format('alter table public.%I enable row level security', tbl);
  end loop;
end $$;
create policy "profiles owner access" on public.profiles for all to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));
create policy "settings owner access" on public.user_settings for all to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
do $$ declare tbl text; begin
  foreach tbl in array array['accounts','transactions','transaction_splits','budgets','recurring_transactions','recurring_occurrences','bills','financial_goals','goal_contributions','attachments','notifications'] loop
    execute format('create policy %I on public.%I for all to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()))', tbl || ' owner access', tbl);
  end loop;
end $$;
create policy "account postings owner read" on public.account_postings for select to authenticated using ((select auth.uid()) = user_id);
create policy "audit log owner read" on public.audit_logs for select to authenticated using ((select auth.uid()) = user_id);
create policy "audit log owner append" on public.audit_logs for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "categories visible to owner" on public.categories for select to authenticated using (user_id = (select auth.uid()) or user_id is null);
create policy "categories owner changes" on public.categories for all to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

create or replace function public.set_updated_at() returns trigger language plpgsql as $$ begin new.updated_at = now(); return new; end $$;
create trigger profiles_updated_at before update on public.profiles for each row execute function public.set_updated_at();
create trigger accounts_updated_at before update on public.accounts for each row execute function public.set_updated_at();
create trigger transactions_updated_at before update on public.transactions for each row execute function public.set_updated_at();
create trigger budgets_updated_at before update on public.budgets for each row execute function public.set_updated_at();
create trigger user_settings_updated_at before update on public.user_settings for each row execute function public.set_updated_at();

-- Maintain a signed account ledger atomically with each transaction write.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
create or replace function private.sync_account_postings() returns trigger
language plpgsql security definer set search_path = pg_catalog, public
as $$
declare
  row_user_id uuid;
  posting_date timestamptz;
begin
  row_user_id := case when tg_op = 'DELETE' then old.user_id else new.user_id end;
  if auth.uid() is null or auth.uid() <> row_user_id then
    raise exception 'transaction owner does not match authenticated user' using errcode = '42501';
  end if;
  if tg_op <> 'INSERT' then
    delete from public.account_postings where transaction_id = old.id and user_id = old.user_id;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  if new.status = 'posted' then
    posting_date := new.transaction_date::timestamp at time zone 'Asia/Kolkata';
    if new.transaction_time is not null then
      posting_date := (new.transaction_date + new.transaction_time) at time zone 'Asia/Kolkata';
    end if;
    if new.transaction_type in ('transfer','credit_card_payment') then
      insert into public.account_postings(user_id, transaction_id, account_id, amount, posted_at)
      values (new.user_id, new.id, new.account_id, -new.amount, posting_date),
             (new.user_id, new.id, new.destination_account_id, new.amount, posting_date);
    else
      insert into public.account_postings(user_id, transaction_id, account_id, amount, posted_at)
      values (new.user_id, new.id, new.account_id,
              case when new.transaction_type in ('income','refund') then new.amount else -new.amount end,
              posting_date);
    end if;
  end if;
  return new;
end
$$;
revoke all on function private.sync_account_postings() from public, anon, authenticated;
create trigger transaction_postings_after_write
after insert or update or delete on public.transactions
for each row execute function private.sync_account_postings();

-- Create a private receipt bucket after enabling Storage. Apply equivalent owner-folder policies in Supabase Storage.
