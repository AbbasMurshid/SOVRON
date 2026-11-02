begin;
select plan(13);

select ok(
  exists (select 1 from pg_trigger where tgname = 'categories_integrity_guard' and not tgisinternal)
  and exists (select 1 from pg_trigger where tgname = 'transactions_category_guard' and not tgisinternal)
  and exists (select 1 from pg_trigger where tgname = 'splits_category_guard' and not tgisinternal)
  and exists (select 1 from pg_trigger where tgname = 'budgets_category_guard' and not tgisinternal)
  and exists (select 1 from pg_trigger where tgname = 'recurring_category_guard' and not tgisinternal),
  'category ownership guards are installed on all category relationships'
);

select ok(
  exists (select 1 from pg_trigger where tgname = 'transactions_account_integrity_guard' and not tgisinternal),
  'transaction account type and solvency guard is installed'
);

select ok(
  exists (select 1 from pg_constraint where conrelid = 'public.transactions'::regclass and conname = 'transactions_two_sided_target_check')
  and exists (select 1 from pg_constraint where conrelid = 'public.transactions'::regclass and conname = 'transactions_no_self_link_check'),
  'two-sided and self-link transaction constraints are installed'
);

select ok(
  exists (select 1 from pg_constraint where conrelid = 'public.account_postings'::regclass and conname = 'account_postings_transaction_account_uidx'),
  'a transaction cannot post twice to the same account'
);

select ok(
  (select count(*) = 5 from information_schema.columns where table_schema = 'public' and table_name in ('accounts','transactions','budgets','financial_goals','debt_obligations') and column_name = 'version'),
  'version columns exist on synchronized financial records'
);

select ok(
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'goal_contributions' and column_name = 'operation_id')
  and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'debt_payments' and column_name = 'operation_id'),
  'goal and debt operations have stable idempotency keys'
);

select ok(
  (select prosecdef from pg_proc where oid = 'public.record_debt_payment(uuid,uuid,numeric,date,text)'::regprocedure)
  and (select prosecdef from pg_proc where oid = 'public.reset_my_finance_data()'::regprocedure),
  'repayment and reset operations run as narrowly scoped security-definer RPCs'
);

select ok(
  (select count(*) = 4 from pg_proc where proname in ('record_debt_payment','edit_debt_payment','delete_debt_payment','reset_my_finance_data')),
  'all atomic repayment and reset RPCs exist'
);

select ok(
  (select count(*) = 18 from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname in ('profiles','accounts','categories','transactions','transaction_splits','account_postings','budgets','recurring_transactions','recurring_occurrences','bills','financial_goals','goal_contributions','attachments','notifications','audit_logs','user_settings','debt_obligations','debt_payments') and c.relrowsecurity),
  'RLS remains enabled on all 18 user and financial tables'
);

select ok(not exists (
  select 1 from public.transactions t join public.categories c on c.id = t.category_id
  where c.user_id is not null and c.user_id <> t.user_id
  union all
  select 1 from public.transaction_splits s join public.categories c on c.id = s.category_id
  where c.user_id is not null and c.user_id <> s.user_id
  union all
  select 1 from public.budgets b join public.categories c on c.id = b.category_id
  where c.user_id is not null and c.user_id <> b.user_id
  union all
  select 1 from public.recurring_transactions r join public.categories c on c.id = r.category_id
  where c.user_id is not null and c.user_id <> r.user_id
  union all
  select 1 from public.categories child join public.categories parent on parent.id = child.parent_id
  where parent.user_id is not null and parent.user_id <> child.user_id
), 'category links are global or same-owner');

select ok(not exists (
  select 1 from public.attachments a join public.transactions t on t.id = a.transaction_id where a.transaction_id is not null and a.user_id <> t.user_id
  union all
  select 1 from public.goal_contributions gc join public.financial_goals g on g.id = gc.goal_id where gc.user_id <> g.user_id
  union all
  select 1 from public.goal_contributions gc join public.transactions t on t.id = gc.transaction_id where gc.transaction_id is not null and gc.user_id <> t.user_id
  union all
  select 1 from public.recurring_occurrences o join public.recurring_transactions r on r.id = o.recurring_id where o.user_id <> r.user_id
  union all
  select 1 from public.recurring_occurrences o join public.transactions t on t.id = o.transaction_id where o.transaction_id is not null and o.user_id <> t.user_id
  union all
  select 1 from public.transactions t join public.transactions linked on linked.id = t.linked_transaction_id where t.linked_transaction_id is not null and t.user_id <> linked.user_id
), 'attachments, goal, recurring and linked-transaction references remain owner-scoped');

select ok(not exists (
  select 1 from public.debt_obligations d
  left join (select debt_id, sum(amount) paid from public.debt_payments group by debt_id) p on p.debt_id = d.id
  where round(d.remaining, 2) <> round(d.amount - coalesce(p.paid, 0), 2)
), 'stored debt balances agree with repayment history');

select ok(not exists (
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
    select transaction_id as id, user_id, account_id, amount from public.account_postings
  ), differences as (
    (select * from expected except all select * from actual)
    union all
    (select * from actual except all select * from expected)
  ) select 1 from differences
), 'posted and voided transaction rows match their exact ledger postings');

select * from finish();
rollback;
