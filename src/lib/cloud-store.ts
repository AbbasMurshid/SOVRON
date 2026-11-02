import type { SupabaseClient } from "@supabase/supabase-js";
import { Account, Budget, Debt, DebtPayment, FinanceState, Goal, sumMoney, Transaction } from "@/lib/finance";

type AccountRow = { id: string; name: string; account_type: string; institution: string | null; opening_balance: number; created_at: string };
type CategoryRow = { id: string; name: string; kind: string };
type TransactionRow = { id: string; transaction_type: string; amount: number; category_id: string | null; account_id: string; destination_account_id: string | null; merchant: string | null; transaction_date: string; notes: string | null; description: string | null; created_at: string };
type BudgetRow = { id: string; name: string; amount: number; starts_on: string };
type GoalRow = { id: string; name: string; target_amount: number; target_date: string | null };
type ContributionRow = { goal_id: string; amount: number };
type DebtRow = { id: string; person: string; direction: "i_owe" | "owed_to_me"; amount: number; remaining: number; due_date: string | null; reminder_date: string | null; note: string | null; created_at: string };
type DebtPaymentRow = { id: string; debt_id: string; amount: number; payment_date: string; note: string | null };
type WriteRow = Record<string, string | number | null | string[]>;
function throwIfError<T extends { error: unknown }>(result: T) { if (result.error) throw result.error; }

export async function loadCloudState(client: SupabaseClient, userId: string): Promise<FinanceState> {
  const [accounts, categories, transactions, budgets, goals, contributions, debts, debtPayments] = await Promise.all([
    client.from("accounts").select("*").eq("user_id", userId),
    client.from("categories").select("id,name,kind").eq("user_id", userId),
    client.from("transactions").select("*").eq("user_id", userId).eq("status", "posted").order("transaction_date", { ascending: false }),
    client.from("budgets").select("*").eq("user_id", userId),
    client.from("financial_goals").select("*").eq("user_id", userId),
    client.from("goal_contributions").select("goal_id,amount").eq("user_id", userId),
    client.from("debt_obligations").select("*").eq("user_id", userId),
    client.from("debt_payments").select("*").eq("user_id", userId),
  ]);
  [accounts, categories, transactions, budgets, goals, contributions, debts, debtPayments].forEach(throwIfError);
  const categoryName = new Map((categories.data as CategoryRow[]).map(row => [row.id, row.name]));
  const goalSaved = new Map<string, number>();
  for (const item of contributions.data as ContributionRow[]) goalSaved.set(item.goal_id, sumMoney([goalSaved.get(item.goal_id) ?? 0, Number(item.amount)]));
  const paymentsByDebt = new Map<string, DebtPayment[]>();
  for (const item of debtPayments.data as DebtPaymentRow[]) paymentsByDebt.set(item.debt_id, [...(paymentsByDebt.get(item.debt_id) ?? []), { id: item.id, amount: Number(item.amount), date: item.payment_date, note: item.note ?? "" }]);
  return {
    accounts: (accounts.data as AccountRow[]).map(row => ({ id: row.id, name: row.name, kind: row.account_type, institution: row.institution ?? "", openingBalance: Number(row.opening_balance), createdAt: row.created_at } satisfies Account)),
    transactions: (transactions.data as TransactionRow[]).map(row => ({
      id: row.id, type: row.transaction_type === "income" ? "income" : row.transaction_type === "refund" ? "refund" : row.transaction_type === "transfer" || row.transaction_type === "credit_card_payment" ? "transfer" : "expense",
      amount: Number(row.amount), category: row.transaction_type === "transfer" || row.transaction_type === "credit_card_payment" ? "Transfer" : (row.category_id ? categoryName.get(row.category_id) : undefined) ?? "Other",
      accountId: row.account_id, ...(row.destination_account_id ? { destinationId: row.destination_account_id } : {}), merchant: row.merchant ?? "", date: row.transaction_date,
      note: row.notes ?? row.description ?? "", createdAt: row.created_at,
    } satisfies Transaction)),
    budgets: (budgets.data as BudgetRow[]).map(row => ({ id: row.id, category: row.name, limit: Number(row.amount), month: row.starts_on.slice(0, 7) } satisfies Budget)),
    goals: (goals.data as GoalRow[]).map(row => ({ id: row.id, name: row.name, target: Number(row.target_amount), saved: goalSaved.get(row.id) ?? 0, due: row.target_date ?? "" } satisfies Goal)),
    debts: (debts.data as DebtRow[]).map(row => ({ id: row.id, person: row.person, direction: row.direction, amount: Number(row.amount), remaining: Number(row.remaining), due: row.due_date ?? "", reminder: row.reminder_date ?? "", note: row.note ?? "", createdAt: row.created_at, payments: paymentsByDebt.get(row.id) ?? [] } satisfies Debt)),
  };
}

/** Persist changed rows only. RLS remains the ownership boundary; every write carries the signed-in user's ID. */
export async function saveCloudState(client: SupabaseClient, userId: string, before: FinanceState, after: FinanceState) {
  await syncRows(client, "accounts", userId, before.accounts, after.accounts, a => ({ id: a.id, user_id: userId, name: a.name, account_type: dbAccountType(a.kind), institution: a.institution || null, opening_balance: a.openingBalance, currency: "INR" }));
  const categoryIds = new Map<string, string>();
  for (const t of after.transactions.filter(t => t.type !== "transfer")) {
    const kind = t.type === "income" ? "income" : "expense";
    const { data, error } = await client.from("categories").upsert({ user_id: userId, kind, name: t.category || "Other" }, { onConflict: "user_id,kind,name" }).select("id").single();
    if (error) throw error;
    categoryIds.set(`${kind}:${t.category || "Other"}`, data.id);
  }
  await syncRows(client, "transactions", userId, before.transactions, after.transactions, t => ({
    id: t.id, user_id: userId, transaction_type: t.type, amount: t.amount, currency: "INR", category_id: t.type === "transfer" ? null : categoryIds.get(`${t.type === "income" ? "income" : "expense"}:${t.category || "Other"}`) ?? null,
    account_id: t.accountId, destination_account_id: t.destinationId ?? null, merchant: t.merchant || null, transaction_date: t.date,
    notes: t.note || null, status: "posted", created_at: t.createdAt, updated_at: new Date().toISOString(),
  }));
  await syncRows(client, "budgets", userId, before.budgets, after.budgets, b => ({ id: b.id, user_id: userId, name: b.category, amount: b.limit, period: "monthly", starts_on: `${b.month}-01`, updated_at: new Date().toISOString() }));

  const beforeGoals = new Map(before.goals.map(g => [g.id, g]));
  for (const goal of after.goals) {
    const { error } = await client.from("financial_goals").upsert({ id: goal.id, user_id: userId, name: goal.name, target_amount: goal.target, target_date: goal.due || null });
    if (error) throw error;
    const delta = sumMoney([goal.saved, -(beforeGoals.get(goal.id)?.saved ?? 0)]);
    if (delta > 0) {
      const { error: contributionError } = await client.from("goal_contributions").insert({ user_id: userId, goal_id: goal.id, amount: delta, contributed_at: new Date().toISOString().slice(0, 10) });
      if (contributionError) throw contributionError;
    }
  }
  await deleteMissing(client, "financial_goals", userId, before.goals, after.goals);
  await syncRows(client, "debt_obligations", userId, before.debts ?? [], after.debts ?? [], d => ({ id: d.id, user_id: userId, person: d.person, direction: d.direction, amount: d.amount, remaining: d.remaining, due_date: d.due || null, reminder_date: d.reminder || null, note: d.note || null, created_at: d.createdAt, updated_at: new Date().toISOString() }));
  const beforePayments = (before.debts ?? []).flatMap(d => d.payments.map(p => ({ ...p, debtId: d.id })));
  const afterPayments = (after.debts ?? []).flatMap(d => d.payments.map(p => ({ ...p, debtId: d.id })));
  await syncRows(client, "debt_payments", userId, beforePayments.map(p => ({ id: p.id, debtId: p.debtId, amount: p.amount, date: p.date, note: p.note })), afterPayments.map(p => ({ id: p.id, debtId: p.debtId, amount: p.amount, date: p.date, note: p.note })), p => ({ id: p.id, user_id: userId, debt_id: p.debtId, amount: p.amount, payment_date: p.date, note: p.note || null }));
}

export async function resetCloudData(client: SupabaseClient, userId: string) {
  // Delete dependents first so account/category foreign keys and ledger triggers stay consistent.
  for (const table of ["debt_payments", "debt_obligations", "transactions", "budgets", "recurring_transactions", "bills", "financial_goals", "accounts", "categories", "notifications"]) {
    const { error } = await client.from(table).delete().eq("user_id", userId);
    if (error) throw error;
  }
}

async function syncRows<T extends { id: string }>(client: SupabaseClient, table: string, userId: string, before: T[], after: T[], toRow: (item: T) => WriteRow) {
  const old = new Map(before.map(item => [item.id, item]));
  for (const item of after) {
    if (JSON.stringify(old.get(item.id)) === JSON.stringify(item)) continue;
    const { error } = await client.from(table).upsert(toRow(item));
    if (error) throw error;
  }
  await deleteMissing(client, table, userId, before, after);
}

async function deleteMissing<T extends { id: string }>(client: SupabaseClient, table: string, userId: string, before: T[], after: T[]) {
  const keep = new Set(after.map(item => item.id));
  const removed = before.filter(item => !keep.has(item.id)).map(item => item.id);
  if (removed.length) {
    const { error } = await client.from(table).delete().eq("user_id", userId).in("id", removed);
    if (error) throw error;
  }
}

function dbAccountType(kind: string) {
  const value = kind.toLowerCase();
  if (value.includes("cash")) return "cash";
  if (value.includes("salary")) return "salary";
  if (value.includes("current")) return "current";
  if (value.includes("wallet")) return "wallet";
  if (value.includes("card")) return "credit_card";
  if (value.includes("liability")) return "other_liability";
  if (value.includes("asset")) return "other_asset";
  return "savings";
}
