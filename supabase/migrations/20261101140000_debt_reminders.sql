-- Track money owed by or to the signed-in user and its repayment history.
create table if not exists public.debt_obligations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  person text not null check (length(trim(person)) > 0),
  direction text not null check (direction in ('i_owe','owed_to_me')),
  amount numeric(19,2) not null check (amount > 0),
  remaining numeric(19,2) not null check (remaining >= 0 and remaining <= amount),
  due_date date,
  reminder_date date,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id)
);

create table if not exists public.debt_payments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  debt_id uuid not null,
  amount numeric(19,2) not null check (amount > 0),
  payment_date date not null default current_date,
  note text,
  created_at timestamptz not null default now(),
  foreign key (debt_id, user_id) references public.debt_obligations(id, user_id) on delete cascade
);

alter table public.debt_obligations enable row level security;
alter table public.debt_payments enable row level security;
create policy "debt obligations owner access" on public.debt_obligations
  for all to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "debt payments owner access" on public.debt_payments
  for all to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create index if not exists debt_obligations_owner_due_idx on public.debt_obligations(user_id, due_date) where remaining > 0;
create index if not exists debt_payments_owner_debt_date_idx on public.debt_payments(user_id, debt_id, payment_date desc);
create trigger debt_obligations_updated_at before update on public.debt_obligations
  for each row execute function public.set_updated_at();
