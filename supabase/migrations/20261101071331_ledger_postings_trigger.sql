-- Follow-up for projects that already applied the initial MyLedger schema.
-- Keep account postings readable to their owner but write them only through the transaction trigger.
drop policy if exists "account_postings owner access" on public.account_postings;
drop policy if exists "account postings owner read" on public.account_postings;
create policy "account postings owner read" on public.account_postings
  for select to authenticated using ((select auth.uid()) = user_id);

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
drop trigger if exists transaction_postings_after_write on public.transactions;
create trigger transaction_postings_after_write
  after insert or update or delete on public.transactions
  for each row execute function private.sync_account_postings();
