-- Atomic finance snapshots, atomic goal funding, and category ownership preflight.
-- The migration adds functions and validation only; it does not rewrite finance rows.

do $$
begin
  if exists (
    select 1 from public.transactions t
    join public.categories c on c.id = t.category_id
    where t.category_id is not null and c.user_id is not null and c.user_id is distinct from t.user_id
  ) or exists (
    select 1 from public.transaction_splits s
    join public.categories c on c.id = s.category_id
    where s.category_id is not null and c.user_id is not null and c.user_id is distinct from s.user_id
  ) or exists (
    select 1 from public.budgets b
    join public.categories c on c.id = b.category_id
    where b.category_id is not null and c.user_id is not null and c.user_id is distinct from b.user_id
  ) then
    raise exception 'MyLedger category preflight failed: transaction, split, or budget references another user''s private category.';
  end if;
end
$$;

create or replace function private.snapshot_row_matches(p_actual jsonb, p_wanted jsonb)
returns boolean language sql immutable set search_path = pg_catalog
as $$
  select p_actual is not null and not exists (
    select 1 from jsonb_each(p_wanted) e
    where e.key not in ('expected_version','version','updated_at','created_at')
      and e.value is distinct from p_actual -> e.key
  )
$$;
revoke all on function private.snapshot_row_matches(jsonb,jsonb) from public, anon, authenticated;

create or replace function private.apply_finance_snapshot_table(
  p_table text, p_user_id uuid, p_writes jsonb, p_deletes jsonb, p_delete_only boolean default false
) returns void language plpgsql security definer set search_path = pg_catalog
as $$
declare
  allowed_columns text[];
  mutable_columns text[];
  item jsonb;
  current_row jsonb;
  expected_version bigint;
  column_sql text;
  select_sql text;
  set_sql text;
  affected integer;
  row_id uuid;
begin
  case p_table
    when 'accounts' then
      allowed_columns := array['id','user_id','name','account_type','institution','opening_balance','currency','created_at'];
      mutable_columns := array['name','account_type','institution','opening_balance','currency'];
    when 'transactions' then
      allowed_columns := array['id','user_id','transaction_type','status','amount','currency','category_id','account_id','destination_account_id','merchant','transaction_date','transaction_time','payment_method','description','notes','tags','receipt_path','linked_transaction_id','created_at'];
      mutable_columns := array['transaction_type','status','amount','currency','category_id','account_id','destination_account_id','merchant','transaction_date','transaction_time','payment_method','description','notes','tags','receipt_path','linked_transaction_id'];
    when 'budgets' then
      allowed_columns := array['id','user_id','name','category_id','amount','period','starts_on','ends_on'];
      mutable_columns := array['name','category_id','amount','period','starts_on','ends_on'];
    when 'financial_goals' then
      allowed_columns := array['id','user_id','name','target_amount','target_date'];
      mutable_columns := array['name','target_amount','target_date'];
    when 'debt_obligations' then
      allowed_columns := array['id','user_id','person','direction','amount','remaining','due_date','reminder_date','note','created_at'];
      mutable_columns := array['person','direction','amount','remaining','due_date','reminder_date','note'];
    else
      raise exception 'Unsupported finance snapshot table.' using errcode = '22023';
  end case;

  if jsonb_typeof(p_writes) is distinct from 'array' or jsonb_typeof(p_deletes) is distinct from 'array' then
    raise exception 'Finance snapshot writes and deletes must be arrays.' using errcode = '22023';
  end if;

  if not p_delete_only then
    for item in select value from jsonb_array_elements(p_writes)
    loop
      if item->>'user_id' is distinct from p_user_id::text or item->>'id' is null then
        raise exception 'Finance snapshot row owner or ID is invalid.' using errcode = '42501';
      end if;
      if exists (select 1 from jsonb_object_keys(item) k where k <> all(allowed_columns || array['expected_version'])) then
        raise exception 'Finance snapshot contains an unsupported column.' using errcode = '22023';
      end if;
      row_id := (item->>'id')::uuid;
      expected_version := nullif(item->>'expected_version','')::bigint;
      current_row := null;
      execute format('select to_jsonb(t) from public.%I t where t.id = $1 and t.user_id = $2 for update', p_table)
        into current_row using row_id, p_user_id;

      if current_row is null then
        if expected_version is not null then
          raise exception 'A finance record was deleted by another session.' using errcode = '40001';
        end if;
        execute format('select to_jsonb(t) from public.%I t where t.id = $1 for update', p_table) into current_row using row_id;
        if current_row is not null then
          raise exception 'A finance record ID belongs to a different user.' using errcode = '42501';
        end if;
        select string_agg(format('%I', key), ', '), string_agg(format('r.%I', key), ', ')
          into column_sql, select_sql
          from jsonb_object_keys(item) key
          where key = any(allowed_columns);
        execute format('insert into public.%I (%s) select %s from jsonb_populate_record(null::public.%I, $1) r', p_table, column_sql, select_sql, p_table) using item;
        continue;
      end if;

      if expected_version is null then
        if private.snapshot_row_matches(current_row, item) then continue; end if;
        raise exception 'A finance record ID already exists with different data.' using errcode = '23505';
      end if;

      if (current_row->>'version')::bigint <> expected_version then
        if private.snapshot_row_matches(current_row, item) then continue; end if;
        raise exception 'A finance record changed on another device.' using errcode = '40001';
      end if;

      select string_agg(format('%1$I = r.%1$I', key), ', ')
        into set_sql
        from jsonb_object_keys(item) key
        where key = any(mutable_columns);
      if set_sql is not null then
        execute format('update public.%I t set %s from jsonb_populate_record(null::public.%I, $1) r where t.id = $2 and t.user_id = $3 and t.version = $4', p_table, set_sql, p_table)
          using item, row_id, p_user_id, expected_version;
        get diagnostics affected = row_count;
        if affected <> 1 then raise exception 'A finance record changed during save.' using errcode = '40001'; end if;
      end if;
    end loop;
  end if;

  if p_delete_only then
    for item in select value from jsonb_array_elements(p_deletes)
    loop
      row_id := (item->>'id')::uuid;
      expected_version := nullif(item->>'version','')::bigint;
      if expected_version is null then raise exception 'A version is required to delete a finance record.' using errcode = '22023'; end if;
      current_row := null;
      execute format('select to_jsonb(t) from public.%I t where t.id = $1 and t.user_id = $2 for update', p_table)
        into current_row using row_id, p_user_id;
      if current_row is null then continue; end if;
      if (current_row->>'version')::bigint <> expected_version then raise exception 'A finance record changed on another device and was not deleted.' using errcode = '40001'; end if;
      execute format('delete from public.%I where id = $1 and user_id = $2 and version = $3', p_table)
        using row_id, p_user_id, expected_version;
      get diagnostics affected = row_count;
      if affected <> 1 then raise exception 'A finance record changed during deletion.' using errcode = '40001'; end if;
    end loop;
  end if;
end
$$;
revoke all on function private.apply_finance_snapshot_table(text,uuid,jsonb,jsonb,boolean) from public, anon, authenticated;

create or replace function public.save_finance_state(p_snapshot jsonb)
returns void language plpgsql security definer set search_path = pg_catalog
as $$
declare uid uuid := auth.uid(); section text; table_name text;
begin
  if uid is null then raise exception 'Authentication required.' using errcode = '42501'; end if;
  if jsonb_typeof(p_snapshot) is distinct from 'object' then raise exception 'Finance snapshot must be an object.' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended(uid::text, 18431));

  foreach section in array array['accounts','transactions','budgets','financial_goals','debt_obligations'] loop
    if jsonb_typeof(p_snapshot->section->'writes') is distinct from 'array' or jsonb_typeof(p_snapshot->section->'deletes') is distinct from 'array' then
      raise exception 'Finance snapshot is missing a valid section: %.', section using errcode = '22023';
    end if;
  end loop;

  -- Insert/update parents before dependent transaction rows. Any failure rolls back the entire RPC.
  perform private.apply_finance_snapshot_table('accounts', uid, p_snapshot->'accounts'->'writes', p_snapshot->'accounts'->'deletes');
  perform private.apply_finance_snapshot_table('financial_goals', uid, p_snapshot->'financial_goals'->'writes', p_snapshot->'financial_goals'->'deletes');
  perform private.apply_finance_snapshot_table('transactions', uid, p_snapshot->'transactions'->'writes', p_snapshot->'transactions'->'deletes');
  perform private.apply_finance_snapshot_table('budgets', uid, p_snapshot->'budgets'->'writes', p_snapshot->'budgets'->'deletes');
  perform private.apply_finance_snapshot_table('debt_obligations', uid, p_snapshot->'debt_obligations'->'writes', p_snapshot->'debt_obligations'->'deletes');

  -- Delete dependents before accounts; all deletes still share this transaction.
  perform private.apply_finance_snapshot_table('transactions', uid, '[]'::jsonb, p_snapshot->'transactions'->'deletes', true);
  perform private.apply_finance_snapshot_table('budgets', uid, '[]'::jsonb, p_snapshot->'budgets'->'deletes', true);
  perform private.apply_finance_snapshot_table('financial_goals', uid, '[]'::jsonb, p_snapshot->'financial_goals'->'deletes', true);
  perform private.apply_finance_snapshot_table('debt_obligations', uid, '[]'::jsonb, p_snapshot->'debt_obligations'->'deletes', true);
  perform private.apply_finance_snapshot_table('accounts', uid, '[]'::jsonb, p_snapshot->'accounts'->'deletes', true);
end
$$;
revoke all on function public.save_finance_state(jsonb) from public, anon;
grant execute on function public.save_finance_state(jsonb) to authenticated;

create or replace function public.record_goal_contribution(
  p_operation_id uuid, p_goal_id uuid, p_amount numeric, p_contributed_at date,
  p_account_id uuid, p_transaction_id uuid, p_source_account_id uuid,
  p_merchant text, p_note text
) returns table(contribution_id uuid, transaction_id uuid)
language plpgsql security definer set search_path = pg_catalog
as $$
declare uid uuid := auth.uid(); prior public.goal_contributions%rowtype; tx public.transactions%rowtype;
begin
  if uid is null then raise exception 'Authentication required.' using errcode = '42501'; end if;
  if p_operation_id is null or p_goal_id is null or p_amount is null or p_amount <= 0 or p_contributed_at is null then
    raise exception 'A valid operation ID, goal, date, and positive amount are required.' using errcode = '22023';
  end if;
  if (p_transaction_id is null) <> (p_source_account_id is null) then
    raise exception 'A transfer requires both a transaction ID and a source account.' using errcode = '22023';
  end if;
  if p_transaction_id is null and p_source_account_id is not null then raise exception 'Manual contributions cannot include transfer details.' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended(uid::text || ':' || p_operation_id::text, 0));

  select * into prior from public.goal_contributions c where c.user_id = uid and c.operation_id = p_operation_id;
  if found then
    if prior.id <> p_operation_id or prior.goal_id <> p_goal_id or round(prior.amount,2) <> round(p_amount,2)
      or prior.contributed_at <> p_contributed_at or prior.account_id is distinct from p_account_id
      or prior.transaction_id is distinct from p_transaction_id then
      raise exception 'Idempotency key was reused with different contribution details.' using errcode = '22023';
    end if;
    if p_transaction_id is not null then
      select * into tx from public.transactions t where t.id = p_transaction_id and t.user_id = uid;
      if not found or tx.transaction_type <> 'transfer' or tx.account_id <> p_source_account_id
        or tx.destination_account_id <> p_account_id or round(tx.amount,2) <> round(p_amount,2)
        or tx.transaction_date <> p_contributed_at
        or tx.merchant is distinct from coalesce(nullif(trim(p_merchant),''),'Savings goal transfer')
        or coalesce(tx.notes,'') is distinct from coalesce(nullif(trim(p_note),''),'') then
        raise exception 'The saved contribution transfer does not match its operation.' using errcode = '22023';
      end if;
    end if;
    return query select prior.id, prior.transaction_id;
    return;
  end if;

  perform 1 from public.financial_goals g where g.id = p_goal_id and g.user_id = uid for update;
  if not found then raise exception 'Savings goal not found.' using errcode = 'P0002'; end if;

  if p_transaction_id is not null then
    if p_account_id is null or p_source_account_id = p_account_id then raise exception 'Choose two different owned accounts.' using errcode = '22023'; end if;
    insert into public.transactions(id,user_id,transaction_type,status,amount,currency,category_id,account_id,destination_account_id,merchant,transaction_date,description,notes)
    values (p_transaction_id,uid,'transfer','posted',round(p_amount,2),'INR',null,p_source_account_id,p_account_id,
      coalesce(nullif(trim(p_merchant),''),'Savings goal transfer'),p_contributed_at,
      coalesce(nullif(trim(p_merchant),''),'Savings goal transfer'),nullif(trim(p_note),''));
  elsif p_account_id is not null then
    perform 1 from public.accounts a where a.id = p_account_id and a.user_id = uid;
    if not found then raise exception 'Contribution account is not owned by this user.' using errcode = '23503'; end if;
  end if;

  insert into public.goal_contributions(id,user_id,goal_id,amount,contributed_at,account_id,transaction_id,operation_id)
  values (p_operation_id,uid,p_goal_id,round(p_amount,2),p_contributed_at,p_account_id,p_transaction_id,p_operation_id);
  return query select p_operation_id, p_transaction_id;
end
$$;
revoke all on function public.record_goal_contribution(uuid,uuid,numeric,date,uuid,uuid,uuid,text,text) from public, anon;
grant execute on function public.record_goal_contribution(uuid,uuid,numeric,date,uuid,uuid,uuid,text,text) to authenticated;

-- Return the versions written by the database; callers must not predict trigger increments.
create or replace function public.edit_debt_payment_v2(
  p_payment_id uuid, p_expected_version bigint, p_amount numeric, p_payment_date date, p_note text default null
) returns table(remaining numeric(19,2), debt_version bigint, payment_version bigint)
language plpgsql security definer set search_path = pg_catalog
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
  if p_amount is null or p_amount <= 0 or p_payment_date is null then raise exception 'Payment amount and date are required.' using errcode = '22023'; end if;
  select coalesce(sum(amount),0) - p.amount + round(p_amount,2) into paid from public.debt_payments where debt_id = p.debt_id and user_id = uid;
  if round(paid,2) > round(d.amount,2) then raise exception 'Edited payments would exceed the original debt amount.' using errcode = '23514'; end if;
  new_remaining := round(d.amount - paid,2);
  perform set_config('myledger.debt_rpc','on',true);
  update public.debt_payments set amount = round(p_amount,2), payment_date = p_payment_date, note = nullif(trim(p_note),'') where id = p_payment_id and user_id = uid;
  update public.debt_obligations set remaining = new_remaining where id = d.id and user_id = uid;
  return query select current_debt.remaining, current_debt.version, current_payment.version
    from public.debt_obligations current_debt join public.debt_payments current_payment on current_payment.debt_id = current_debt.id
    where current_debt.id = d.id and current_debt.user_id = uid and current_payment.id = p_payment_id and current_payment.user_id = uid;
end
$$;
revoke all on function public.edit_debt_payment_v2(uuid,bigint,numeric,date,text) from public, anon;
grant execute on function public.edit_debt_payment_v2(uuid,bigint,numeric,date,text) to authenticated;

create or replace function public.delete_debt_payment_v2(p_payment_id uuid, p_expected_version bigint)
returns table(remaining numeric(19,2), debt_version bigint)
language plpgsql security definer set search_path = pg_catalog
as $$
declare uid uuid := auth.uid(); p public.debt_payments%rowtype; d public.debt_obligations%rowtype; paid numeric(19,2); new_remaining numeric(19,2);
begin
  if uid is null then raise exception 'Authentication required.' using errcode = '42501'; end if;
  if p_expected_version is null then raise exception 'A current payment version is required.' using errcode = '22023'; end if;
  select * into p from public.debt_payments where id = p_payment_id and user_id = uid for update;
  if not found then raise exception 'Debt payment not found; reload to confirm its current state.' using errcode = 'P0002'; end if;
  if p.version <> p_expected_version then raise exception 'Debt payment changed elsewhere; reload before deleting.' using errcode = '40001'; end if;
  select * into d from public.debt_obligations where id = p.debt_id and user_id = uid for update;
  if not found then raise exception 'Debt record not found.' using errcode = 'P0002'; end if;
  select coalesce(sum(amount),0) - p.amount into paid from public.debt_payments where debt_id = p.debt_id and user_id = uid;
  new_remaining := round(d.amount - paid,2);
  perform set_config('myledger.debt_rpc','on',true);
  delete from public.debt_payments where id = p_payment_id and user_id = uid;
  update public.debt_obligations set remaining = new_remaining where id = d.id and user_id = uid;
  return query select current_debt.remaining, current_debt.version from public.debt_obligations current_debt where current_debt.id = d.id and current_debt.user_id = uid;
end
$$;
revoke all on function public.delete_debt_payment_v2(uuid,bigint) from public, anon;
grant execute on function public.delete_debt_payment_v2(uuid,bigint) to authenticated;
