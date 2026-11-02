-- Forward-only MyLedger integrity hardening. No existing finance rows are rewritten.
-- Preconditions are checked before owner-scoped constraints are added; a failure aborts the migration.

-- Existing references must be ownership-compatible before their composite constraints are installed.
do $$
begin
  if exists (
    select 1 from public.attachments a join public.transactions t on t.id = a.transaction_id
    where a.transaction_id is not null and a.user_id <> t.user_id
  ) or exists (
    select 1 from public.goal_contributions gc join public.financial_goals g on g.id = gc.goal_id
    where gc.user_id <> g.user_id
  ) or exists (
    select 1 from public.goal_contributions gc join public.transactions t on t.id = gc.transaction_id
    where gc.transaction_id is not null and gc.user_id <> t.user_id
  ) or exists (
    select 1 from public.recurring_occurrences ro join public.recurring_transactions rt on rt.id = ro.recurring_id
    where ro.user_id <> rt.user_id
  ) or exists (
    select 1 from public.recurring_occurrences ro join public.transactions t on t.id = ro.transaction_id
    where ro.transaction_id is not null and ro.user_id <> t.user_id
  ) or exists (
    select 1 from public.transactions tx join public.transactions linked on linked.id = tx.linked_transaction_id
    where tx.linked_transaction_id is not null and tx.user_id <> linked.user_id
  ) or exists (
    select 1 from public.categories child join public.categories parent on parent.id = child.parent_id
    where child.parent_id is not null and parent.user_id is not null and parent.user_id is distinct from child.user_id
  ) or exists (
    select 1 from public.recurring_transactions rt join public.categories c on c.id = rt.category_id
    where rt.category_id is not null and c.user_id is not null and c.user_id <> rt.user_id
  ) then
    raise exception 'MyLedger hardening preflight failed: cross-owner relationships exist; export and reconcile them before retrying.';
  end if;

  if exists (
    select 1 from public.debt_obligations d
    left join (select debt_id, sum(amount) as paid from public.debt_payments group by debt_id) p on p.debt_id = d.id
    where round(d.remaining, 2) <> round(d.amount - coalesce(p.paid, 0), 2)
  ) then
    raise exception 'MyLedger hardening preflight failed: a debt remaining balance differs from its repayment history; reconcile before retrying.';
  end if;

  if exists (
    select transaction_id, account_id from public.account_postings
    group by transaction_id, account_id having count(*) > 1
  ) then
    raise exception 'MyLedger hardening preflight failed: duplicate account postings exist; reconcile before retrying.';
  end if;

  if exists (
    select 1 from public.transactions t where t.status = 'posted' and
      ((t.transaction_type in ('transfer','credit_card_payment') and (t.destination_account_id is null or t.destination_account_id = t.account_id))
       or (t.transaction_type not in ('transfer','credit_card_payment') and t.destination_account_id is not null))
  ) then
    raise exception 'MyLedger hardening preflight failed: posted transactions have invalid two-sided account details; reconcile before retrying.';
  end if;
  if exists (
    select 1 from public.transactions t where t.status = 'posted' and
      (select count(*) from public.account_postings p where p.transaction_id = t.id) <>
      case when t.transaction_type in ('transfer','credit_card_payment') then 2 else 1 end
  ) or exists (
    select 1 from public.transactions t join public.account_postings p on p.transaction_id = t.id
    where t.status = 'voided'
  ) then
    raise exception 'MyLedger hardening preflight failed: posting rows do not match transaction status/type; reconcile before retrying.';
  end if;
  if exists (
    with expected as (
      select t.id, t.user_id, t.account_id,
        case when t.transaction_type in ('income','refund') then t.amount else -t.amount end as amount
      from public.transactions t where t.status = 'posted' and t.transaction_type not in ('transfer','credit_card_payment')
      union all
      select t.id, t.user_id, t.destination_account_id, t.amount
      from public.transactions t where t.status = 'posted' and t.transaction_type in ('transfer','credit_card_payment')
      union all
      select t.id, t.user_id, t.account_id, -t.amount
      from public.transactions t where t.status = 'posted' and t.transaction_type in ('transfer','credit_card_payment')
    ), actual as (
      select p.transaction_id, p.user_id, p.account_id, p.amount from public.account_postings p
    ), differences as (
      (select * from expected except all select * from actual)
      union all
      (select * from actual except all select * from expected)
    ) select 1 from differences
  ) then
    raise exception 'MyLedger hardening preflight failed: posted transaction amounts/accounts differ from ledger postings; reconcile before retrying.';
  end if;
  if exists (select 1 from public.categories where user_id is null group by kind, name having count(*) > 1) then
    raise exception 'MyLedger hardening preflight failed: duplicate global category names exist; reconcile before retrying.';
  end if;
  if exists (select 1 from public.transactions where linked_transaction_id = id) then
    raise exception 'MyLedger hardening preflight failed: self-linked transactions exist; reconcile before retrying.';
  end if;
  if exists (
    select 1 from public.categories child join public.categories parent on parent.id = child.parent_id
    where child.kind <> parent.kind
  ) then
    raise exception 'MyLedger hardening preflight failed: category parent/child kinds differ; reconcile before retrying.';
  end if;
  if exists (
    with recursive walk(root, node, path, cycle) as (
      select c.id, c.parent_id, array[c.id], c.parent_id = c.id from public.categories c where c.parent_id is not null
      union all
      select w.root, c.parent_id, w.path || c.id, c.parent_id = w.root or c.id = any(w.path)
      from walk w join public.categories c on c.id = w.node where not w.cycle
    ) select 1 from walk where cycle
  ) then
    raise exception 'MyLedger hardening preflight failed: category hierarchy cycles exist; reconcile before retrying.';
  end if;
  if exists (
    select 1 from public.transactions t join public.categories c on c.id = t.category_id
    where (t.transaction_type = 'income' and c.kind <> 'income')
       or (t.transaction_type in ('expense','refund','credit_card_purchase') and c.kind <> 'expense')
  ) or exists (
    select 1 from public.transaction_splits s join public.transactions t on t.id = s.transaction_id join public.categories c on c.id = s.category_id
    where c.kind <> case when t.transaction_type = 'income' then 'income' else 'expense' end
  ) or exists (
    select 1 from public.budgets b join public.categories c on c.id = b.category_id where c.kind <> 'expense'
  ) or exists (
    select 1 from public.recurring_transactions r join public.categories c on c.id = r.category_id where c.kind <> r.transaction_type
  ) then
    raise exception 'MyLedger hardening preflight failed: category kind does not match existing records; reconcile before retrying.';
  end if;
end
$$;

-- Category IDs can refer to either a global category or one owned by the row's user.
-- Keep each simple FK for its original ON DELETE behavior; triggers enforce ownership and kind.
alter table public.transactions drop constraint if exists transactions_category_id_user_id_fkey;
alter table public.transaction_splits drop constraint if exists transaction_splits_category_id_user_id_fkey;
alter table public.budgets drop constraint if exists budgets_category_id_user_id_fkey;
alter table public.budgets add constraint budgets_category_id_fkey
  foreign key (category_id) references public.categories(id) on delete cascade;
create unique index if not exists categories_global_kind_name_uidx
  on public.categories(kind, name) where user_id is null;

create or replace function private.validate_category_reference(p_category_id uuid, p_owner uuid, p_kind text default null)
returns void language plpgsql security definer set search_path = pg_catalog, public
as $$
declare category_owner uuid; category_kind text;
begin
  perform pg_advisory_xact_lock(761445, 1);
  select c.user_id, c.kind into category_owner, category_kind
  from public.categories c where c.id = p_category_id;
  if not found then raise exception 'Category does not exist.' using errcode = '23503'; end if;
  if category_owner is not null and category_owner is distinct from p_owner then
    raise exception 'A record can reference only a global category or one owned by its user.' using errcode = '23514';
  end if;
  if p_kind is not null and category_kind <> p_kind then
    raise exception 'Category kind does not match the record.' using errcode = '23514';
  end if;
end
$$;
revoke all on function private.validate_category_reference(uuid, uuid, text) from public, anon, authenticated;

create or replace function private.guard_category_row()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
declare parent_owner uuid; parent_kind text;
begin
  -- Serialize references with ownership changes so a concurrent insert cannot pass a
  -- trigger check just before this category is reassigned.
  perform pg_advisory_xact_lock(761445, 1);
  if tg_op = 'DELETE' then
    if auth.uid() is not null and old.user_id is null then raise exception 'Global categories are read-only.' using errcode = '42501'; end if;
    return old;
  end if;

  if tg_op = 'UPDATE' then
    if auth.uid() is not null and old.user_id is null then raise exception 'Global categories are read-only.' using errcode = '42501'; end if;
    if (new.user_id is distinct from old.user_id or new.kind is distinct from old.kind) and (
      exists (select 1 from public.transactions where category_id = old.id)
      or exists (select 1 from public.transaction_splits where category_id = old.id)
      or exists (select 1 from public.budgets where category_id = old.id)
      or exists (select 1 from public.recurring_transactions where category_id = old.id)
      or exists (select 1 from public.categories where parent_id = old.id)
    ) then raise exception 'Category ownership or kind cannot change while records reference it.' using errcode = '23514'; end if;
  end if;

  if new.parent_id is not null then
    if new.parent_id = new.id then raise exception 'A category cannot be its own parent.' using errcode = '23514'; end if;
    select user_id, kind into parent_owner, parent_kind from public.categories where id = new.parent_id;
    if not found then raise exception 'Parent category does not exist.' using errcode = '23503'; end if;
    if parent_owner is not null and parent_owner is distinct from new.user_id then
      raise exception 'A category parent must be global or owned by the same user.' using errcode = '23514';
    end if;
    if parent_kind <> new.kind then raise exception 'Parent and child categories must have the same kind.' using errcode = '23514'; end if;
    if exists (
      with recursive ancestors(id) as (
        select new.parent_id
        union
        select c.parent_id from public.categories c join ancestors a on c.id = a.id where c.parent_id is not null
      ) select 1 from ancestors where id = new.id
    ) then raise exception 'Category hierarchy cycles are not allowed.' using errcode = '23514'; end if;
  end if;
  return new;
end
$$;
drop trigger if exists categories_integrity_guard on public.categories;
create trigger categories_integrity_guard before insert or update or delete on public.categories
for each row execute function private.guard_category_row();
revoke all on function private.guard_category_row() from public, anon, authenticated;

create or replace function private.guard_category_reference()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
declare expected_kind text;
begin
  if new.category_id is null then return new; end if;
  if tg_table_name = 'transactions' then
    expected_kind := case when new.transaction_type = 'income' then 'income' when new.transaction_type in ('transfer','credit_card_payment') then null else 'expense' end;
  elsif tg_table_name = 'budgets' then expected_kind := 'expense';
  elsif tg_table_name = 'recurring_transactions' then expected_kind := new.transaction_type;
  elsif tg_table_name = 'transaction_splits' then
    select case when t.transaction_type = 'income' then 'income' else 'expense' end into expected_kind
    from public.transactions t where t.id = new.transaction_id and t.user_id = new.user_id;
  end if;
  perform private.validate_category_reference(new.category_id, new.user_id, expected_kind);
  return new;
end
$$;
revoke all on function private.guard_category_reference() from public, anon, authenticated;
create trigger transactions_category_guard before insert or update of category_id, user_id, transaction_type on public.transactions
for each row execute function private.guard_category_reference();
create trigger splits_category_guard before insert or update of category_id, user_id, transaction_id on public.transaction_splits
for each row execute function private.guard_category_reference();
create trigger budgets_category_guard before insert or update of category_id, user_id on public.budgets
for each row execute function private.guard_category_reference();
create trigger recurring_category_guard before insert or update of category_id, user_id, transaction_type on public.recurring_transactions
for each row execute function private.guard_category_reference();

-- Add same-owner foreign keys to relations that previously checked only object existence.
alter table public.financial_goals add constraint financial_goals_id_user_id_key unique (id, user_id);
alter table public.recurring_transactions add constraint recurring_transactions_id_user_id_key unique (id, user_id);
alter table public.attachments drop constraint if exists attachments_transaction_id_fkey;
alter table public.attachments add constraint attachments_transaction_id_user_id_fkey
  foreign key (transaction_id, user_id) references public.transactions(id, user_id) on delete cascade;
alter table public.goal_contributions drop constraint if exists goal_contributions_goal_id_fkey;
alter table public.goal_contributions add constraint goal_contributions_goal_id_user_id_fkey
  foreign key (goal_id, user_id) references public.financial_goals(id, user_id) on delete cascade;
alter table public.goal_contributions drop constraint if exists goal_contributions_transaction_id_fkey;
alter table public.goal_contributions add constraint goal_contributions_transaction_id_user_id_fkey
  foreign key (transaction_id, user_id) references public.transactions(id, user_id) on delete set null (transaction_id);
alter table public.recurring_occurrences drop constraint if exists recurring_occurrences_recurring_id_fkey;
alter table public.recurring_occurrences add constraint recurring_occurrences_recurring_id_user_id_fkey
  foreign key (recurring_id, user_id) references public.recurring_transactions(id, user_id) on delete cascade;
alter table public.recurring_occurrences drop constraint if exists recurring_occurrences_transaction_id_fkey;
alter table public.recurring_occurrences add constraint recurring_occurrences_transaction_id_user_id_fkey
  foreign key (transaction_id, user_id) references public.transactions(id, user_id) on delete set null (transaction_id);
alter table public.transactions drop constraint if exists transactions_linked_transaction_id_fkey;
alter table public.transactions add constraint transactions_linked_transaction_id_user_id_fkey
  foreign key (linked_transaction_id, user_id) references public.transactions(id, user_id) on delete set null (linked_transaction_id);
alter table public.transactions add constraint transactions_no_self_link_check
  check (linked_transaction_id is null or linked_transaction_id <> id);

create index if not exists attachments_owner_transaction_idx on public.attachments(user_id, transaction_id);
create index if not exists goal_contributions_owner_transaction_idx on public.goal_contributions(user_id, transaction_id) where transaction_id is not null;
create index if not exists recurring_occurrences_owner_transaction_idx on public.recurring_occurrences(user_id, transaction_id) where transaction_id is not null;
create index if not exists transactions_owner_account_idx on public.transactions(user_id, account_id, transaction_date desc);
create index if not exists transactions_owner_destination_idx on public.transactions(user_id, destination_account_id) where destination_account_id is not null;

-- Version columns support compare-and-swap edits instead of last-write-wins overwrites.
alter table public.accounts add column if not exists version bigint not null default 1 check (version > 0);
alter table public.transactions add column if not exists version bigint not null default 1 check (version > 0);
alter table public.budgets add column if not exists version bigint not null default 1 check (version > 0);
alter table public.financial_goals add column if not exists updated_at timestamptz not null default now();
alter table public.financial_goals add column if not exists version bigint not null default 1 check (version > 0);
alter table public.debt_obligations add column if not exists version bigint not null default 1 check (version > 0);
alter table public.debt_payments add column if not exists operation_id uuid not null default gen_random_uuid();
alter table public.debt_payments add column if not exists version bigint not null default 1 check (version > 0);
alter table public.debt_payments add column if not exists updated_at timestamptz not null default now();
create unique index if not exists debt_payments_owner_operation_uidx on public.debt_payments(user_id, operation_id);
alter table public.goal_contributions add column if not exists operation_id uuid not null default gen_random_uuid();
create unique index if not exists goal_contributions_owner_operation_uidx on public.goal_contributions(user_id, operation_id);

create or replace function private.bump_row_version()
returns trigger language plpgsql set search_path = pg_catalog
as $$ begin new.updated_at := clock_timestamp(); new.version := old.version + 1; return new; end $$;
drop trigger if exists accounts_updated_at on public.accounts;
drop trigger if exists transactions_updated_at on public.transactions;
drop trigger if exists budgets_updated_at on public.budgets;
drop trigger if exists financial_goals_updated_at_version on public.financial_goals;
drop trigger if exists debt_obligations_updated_at on public.debt_obligations;
create trigger accounts_updated_at_version before update on public.accounts for each row execute function private.bump_row_version();
create trigger transactions_updated_at_version before update on public.transactions for each row execute function private.bump_row_version();
create trigger budgets_updated_at_version before update on public.budgets for each row execute function private.bump_row_version();
create trigger financial_goals_updated_at_version before update on public.financial_goals for each row execute function private.bump_row_version();
create trigger debt_obligations_updated_at_version before update on public.debt_obligations for each row execute function private.bump_row_version();
create trigger debt_payments_updated_at_version before update on public.debt_payments for each row execute function private.bump_row_version();
revoke all on function private.bump_row_version() from public, anon, authenticated;

-- Enforce card/transfer account combinations and asset-account solvency under row locks.
alter table public.transactions add constraint transactions_two_sided_target_check
  check (transaction_type not in ('transfer','credit_card_payment') or (destination_account_id is not null and destination_account_id <> account_id));
create or replace function private.guard_transaction_accounts()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
declare source_type text; source_opening numeric(19,2); destination_type text; available numeric(19,2);
begin
  if tg_op = 'UPDATE'
    and new.user_id is not distinct from old.user_id
    and new.transaction_type is not distinct from old.transaction_type
    and new.status is not distinct from old.status
    and new.amount is not distinct from old.amount
    and new.account_id is not distinct from old.account_id
    and new.destination_account_id is not distinct from old.destination_account_id then
    return new;
  end if;

  if tg_op = 'UPDATE' then
    perform a.id from public.accounts a
      where a.user_id = new.user_id and a.id in (new.account_id, old.account_id)
      order by a.id for update;
  else
    perform a.id from public.accounts a where a.user_id = new.user_id and a.id = new.account_id for update;
  end if;
  select a.account_type, a.opening_balance into source_type, source_opening
    from public.accounts a where a.id = new.account_id and a.user_id = new.user_id;
  if not found then raise exception 'Transaction source account is not owned by this user.' using errcode = '23503'; end if;
  if new.destination_account_id is not null then
    select a.account_type into destination_type from public.accounts a
      where a.id = new.destination_account_id and a.user_id = new.user_id;
    if not found then raise exception 'Transaction destination account is not owned by this user.' using errcode = '23503'; end if;
  end if;

  if new.transaction_type in ('expense','income','transfer') and source_type in ('credit_card','other_liability') then
    raise exception 'Use a credit-card transaction type for card accounts; liability accounts cannot be ordinary transaction sources.' using errcode = '23514';
  end if;
  if new.transaction_type = 'credit_card_purchase' and source_type <> 'credit_card' then
    raise exception 'Credit card purchases must use a credit card account.' using errcode = '23514';
  end if;
  if new.transaction_type = 'credit_card_payment' and
    (source_type in ('credit_card','other_liability') or destination_type <> 'credit_card' or new.destination_account_id = new.account_id) then
    raise exception 'A card payment must move funds from an asset account to a different credit card account.' using errcode = '23514';
  end if;
  if new.transaction_type = 'transfer' and
    (destination_type in ('credit_card','other_liability') or new.destination_account_id = new.account_id) then
    raise exception 'A transfer must move funds between two different asset accounts; use credit-card payment for a card.' using errcode = '23514';
  end if;
  if new.transaction_type = 'refund' and source_type = 'other_liability' then
    raise exception 'Refunds must post to an asset or credit-card account.' using errcode = '23514';
  end if;

  if new.status = 'posted' and new.transaction_type in ('expense','transfer','credit_card_payment') then
    select source_opening + coalesce(sum(p.amount), 0) into available from public.account_postings p
      where p.user_id = new.user_id and p.account_id = new.account_id and p.transaction_id <> new.id;
    if round(available, 2) < round(new.amount, 2) then
      raise exception 'Insufficient available balance. Available %, requested %.', greatest(available, 0), new.amount using errcode = '23514';
    end if;
  end if;
  return new;
end
$$;
drop trigger if exists transactions_account_integrity_guard on public.transactions;
create trigger transactions_account_integrity_guard before insert or update on public.transactions
for each row execute function private.guard_transaction_accounts();
revoke all on function private.guard_transaction_accounts() from public, anon, authenticated;

-- Rebuild postings atomically; ordinary authenticated deletes are already owner-filtered by RLS.
-- Do not reject privileged auth-user cascades where auth.uid() is NULL.
create or replace function private.sync_account_postings() returns trigger
language plpgsql security definer set search_path = pg_catalog, public
as $$
declare posting_date timestamptz;
begin
  if tg_op <> 'DELETE' and auth.uid() is not null and auth.uid() <> new.user_id then
    raise exception 'transaction owner does not match authenticated user' using errcode = '42501';
  end if;
  if tg_op <> 'INSERT' then delete from public.account_postings where transaction_id = old.id and user_id = old.user_id; end if;
  if tg_op = 'DELETE' then return old; end if;
  if new.status = 'posted' then
    posting_date := new.transaction_date::timestamp at time zone 'Asia/Kolkata';
    if new.transaction_time is not null then posting_date := (new.transaction_date + new.transaction_time) at time zone 'Asia/Kolkata'; end if;
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
alter table public.account_postings add constraint account_postings_transaction_account_uidx unique (transaction_id, account_id);
revoke all on function private.sync_account_postings() from public, anon, authenticated;

-- Debt remaining equals principal minus the immutable payment ledger. Only the RPC can write payments.
create or replace function private.guard_debt_balance()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
declare paid numeric(19,2);
begin
  if tg_op = 'INSERT' then
    if round(new.remaining,2) <> round(new.amount,2) then raise exception 'A new debt must begin with its full amount outstanding.' using errcode = '23514'; end if;
    return new;
  end if;
  if new.user_id <> old.user_id then raise exception 'Debt ownership cannot change.' using errcode = '42501'; end if;
  if new.amount is distinct from old.amount and exists (select 1 from public.debt_payments p where p.debt_id = old.id) then
    raise exception 'Principal cannot change after repayments have been recorded.' using errcode = '23514';
  end if;
  select coalesce(sum(p.amount),0) into paid from public.debt_payments p where p.debt_id = old.id and p.user_id = old.user_id;
  if new.remaining is distinct from old.remaining then
    if current_setting('myledger.debt_rpc', true) is distinct from 'on' then raise exception 'Use the debt repayment operation to change the remaining balance.' using errcode = '42501'; end if;
  end if;
  if round(new.remaining,2) <> round(new.amount - paid,2) then raise exception 'Debt balance does not match its repayment history.' using errcode = '23514'; end if;
  return new;
end
$$;
drop trigger if exists debt_obligations_balance_guard on public.debt_obligations;
create trigger debt_obligations_balance_guard before insert or update on public.debt_obligations
for each row execute function private.guard_debt_balance();
revoke all on function private.guard_debt_balance() from public, anon, authenticated;

drop policy if exists "debt payments owner access" on public.debt_payments;
create policy "debt payments owner read" on public.debt_payments for select to authenticated using ((select auth.uid()) = user_id);
revoke insert, update, delete on public.debt_payments from anon, authenticated;

create or replace function public.record_debt_payment(p_debt_id uuid, p_operation_id uuid, p_amount numeric, p_payment_date date default current_date, p_note text default null)
returns table(payment_id uuid, remaining numeric(19,2), debt_version bigint, payment_version bigint) language plpgsql security definer set search_path = pg_catalog, public
as $$
declare uid uuid := auth.uid(); debt_row public.debt_obligations%rowtype; prior public.debt_payments%rowtype;
begin
  if uid is null then raise exception 'Authentication required.' using errcode = '42501'; end if;
  if p_operation_id is null or p_amount is null or p_amount <= 0 or p_payment_date is null then raise exception 'A valid operation ID, date, and positive payment are required.' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_operation_id::text, 0));
  select * into prior from public.debt_payments p where p.user_id = uid and p.operation_id = p_operation_id;
  if found then
    if prior.debt_id <> p_debt_id or round(prior.amount,2) <> round(p_amount,2) or prior.payment_date <> p_payment_date or coalesce(prior.note,'') <> coalesce(nullif(trim(p_note),''),'') then
      raise exception 'Idempotency key was reused with different payment details.' using errcode = '22023';
    end if;
    return query select prior.id, d.remaining, d.version, prior.version from public.debt_obligations d where d.id = p_debt_id and d.user_id = uid;
    return;
  end if;
  select * into debt_row from public.debt_obligations d where d.id = p_debt_id and d.user_id = uid for update;
  if not found then raise exception 'Debt record not found.' using errcode = 'P0002'; end if;
  if round(p_amount,2) > round(debt_row.remaining,2) then raise exception 'Payment exceeds the remaining debt balance.' using errcode = '23514'; end if;
  perform set_config('myledger.debt_rpc','on',true);
  insert into public.debt_payments(id, user_id, debt_id, operation_id, amount, payment_date, note)
  values (p_operation_id, uid, p_debt_id, p_operation_id, round(p_amount,2), p_payment_date, nullif(trim(p_note),''));
  update public.debt_obligations d set remaining = round(debt_row.remaining - p_amount,2) where d.id = p_debt_id and d.user_id = uid;
  return query select p_operation_id, d.remaining, d.version, (select p.version from public.debt_payments p where p.id = p_operation_id and p.user_id = uid)
    from public.debt_obligations d where d.id = p_debt_id and d.user_id = uid;
end
$$;
revoke all on function public.record_debt_payment(uuid,uuid,numeric,date,text) from public, anon;
grant execute on function public.record_debt_payment(uuid,uuid,numeric,date,text) to authenticated;

create or replace function public.edit_debt_payment(p_payment_id uuid, p_expected_version bigint, p_amount numeric, p_payment_date date, p_note text default null)
returns numeric(19,2) language plpgsql security definer set search_path = pg_catalog, public
as $$
declare uid uuid := auth.uid(); p public.debt_payments%rowtype; d public.debt_obligations%rowtype; paid numeric(19,2); new_remaining numeric(19,2);
begin
  if uid is null then raise exception 'Authentication required.' using errcode = '42501'; end if;
  if p_expected_version is null then raise exception 'A current payment version is required.' using errcode = '22023'; end if;
  select * into p from public.debt_payments where id = p_payment_id and user_id = uid for update;
  if not found then raise exception 'Debt payment not found.' using errcode = 'P0002'; end if;
  if p.version <> p_expected_version then raise exception 'Debt payment changed elsewhere; reload before editing.' using errcode = '40001'; end if;
  select * into d from public.debt_obligations where id = p.debt_id and user_id = uid for update;
  if not found then raise exception 'Debt record not found.' using errcode = 'P0002'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Payment amount must be positive.' using errcode = '22023'; end if;
  select coalesce(sum(amount),0) - p.amount + p_amount into paid from public.debt_payments where debt_id = p.debt_id and user_id = uid;
  if round(paid,2) > round(d.amount,2) then raise exception 'Edited payments would exceed the original debt amount.' using errcode = '23514'; end if;
  new_remaining := round(d.amount - paid,2);
  perform set_config('myledger.debt_rpc','on',true);
  update public.debt_payments set amount = round(p_amount,2), payment_date = p_payment_date, note = nullif(trim(p_note),'') where id = p_payment_id and user_id = uid;
  update public.debt_obligations set remaining = new_remaining where id = d.id and user_id = uid;
  return new_remaining;
end
$$;
revoke all on function public.edit_debt_payment(uuid,bigint,numeric,date,text) from public, anon;
grant execute on function public.edit_debt_payment(uuid,bigint,numeric,date,text) to authenticated;

create or replace function public.delete_debt_payment(p_payment_id uuid, p_expected_version bigint)
returns numeric(19,2) language plpgsql security definer set search_path = pg_catalog, public
as $$
declare uid uuid := auth.uid(); p public.debt_payments%rowtype; d public.debt_obligations%rowtype; paid numeric(19,2); new_remaining numeric(19,2);
begin
  if uid is null then raise exception 'Authentication required.' using errcode = '42501'; end if;
  if p_expected_version is null then raise exception 'A current payment version is required.' using errcode = '22023'; end if;
  select * into p from public.debt_payments where id = p_payment_id and user_id = uid for update;
  if not found then return null; end if;
  if p.version <> p_expected_version then raise exception 'Debt payment changed elsewhere; reload before deleting.' using errcode = '40001'; end if;
  select * into d from public.debt_obligations where id = p.debt_id and user_id = uid for update;
  if not found then raise exception 'Debt record not found.' using errcode = 'P0002'; end if;
  select coalesce(sum(amount),0) - p.amount into paid from public.debt_payments where debt_id = p.debt_id and user_id = uid;
  new_remaining := round(d.amount - paid,2);
  perform set_config('myledger.debt_rpc','on',true);
  delete from public.debt_payments where id = p_payment_id and user_id = uid;
  update public.debt_obligations set remaining = new_remaining where id = d.id and user_id = uid;
  return new_remaining;
end
$$;
revoke all on function public.delete_debt_payment(uuid,bigint) from public, anon;
grant execute on function public.delete_debt_payment(uuid,bigint) to authenticated;

-- Atomic reset of the signed-in user's finance records; preserves auth, profile, settings, and audit history.
create or replace function public.reset_my_finance_data()
returns void language plpgsql security definer set search_path = pg_catalog, public
as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Authentication required.' using errcode = '42501'; end if;
  delete from public.attachments where user_id = uid;
  delete from public.recurring_occurrences where user_id = uid;
  delete from public.goal_contributions where user_id = uid;
  delete from public.debt_payments where user_id = uid;
  delete from public.recurring_transactions where user_id = uid;
  delete from public.debt_obligations where user_id = uid;
  delete from public.transactions where user_id = uid;
  delete from public.budgets where user_id = uid;
  delete from public.bills where user_id = uid;
  delete from public.financial_goals where user_id = uid;
  delete from public.accounts where user_id = uid;
  delete from public.categories where user_id = uid;
  delete from public.notifications where user_id = uid;
end
$$;
revoke all on function public.reset_my_finance_data() from public, anon;
grant execute on function public.reset_my_finance_data() to authenticated;

-- Validation queries for local integration tests and pre-deployment review:
-- 1) Assert each non-global category reference has category.user_id = row.user_id.
-- 2) Assert each attachment/goal/recurrence/link reference has matching user_id.
-- 3) Assert posted transfer/card-payment rows have exactly two postings and all others exactly one.
-- 4) Assert debt.remaining = debt.amount - sum(debt_payments.amount).
-- Rollback: restore the verified pre-migration backup. Do not drop constraints or triggers on a live database
-- without first backing up and reviewing rows that depend on them.
