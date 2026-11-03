import type { SupabaseClient } from "@supabase/supabase-js";
import type { Account, Budget, Debt, DebtPayment, FinanceState, Goal, GoalContribution, Transaction, TxType } from "@/lib/finance";
import { sumMoney } from "@/lib/finance";

type AccountRow = { id: string; name: string; account_type: string; institution: string | null; opening_balance: number; created_at: string; version: number };
type CategoryRow = { id: string; name: string; kind: string; user_id: string | null };
type TransactionRow = { id: string; transaction_type: string; status: "posted" | "voided"; amount: number; category_id: string | null; account_id: string; destination_account_id: string | null; merchant: string | null; transaction_date: string; notes: string | null; description: string | null; created_at: string; version: number };
type BudgetRow = { id: string; name: string; amount: number; starts_on: string; category_id: string | null; version: number };
type GoalRow = { id: string; name: string; target_amount: number; target_date: string | null; version: number };
type ContributionRow = { id: string; goal_id: string; amount: number; contributed_at: string; account_id: string | null; transaction_id: string | null; operation_id: string };
type DebtRow = { id: string; person: string; direction: "i_owe" | "owed_to_me"; amount: number; remaining: number; due_date: string | null; reminder_date: string | null; note: string | null; created_at: string; version: number };
type DebtPaymentRow = { id: string; debt_id: string; operation_id: string; amount: number; payment_date: string; note: string | null; version: number };
type WriteRow = Record<string, string | number | null | string[]>;
type Versioned = { id: string; version?: number };
export class SyncConflictError extends Error { constructor(message = "This record changed on another device. Reload before saving again.") { super(message); this.name = "SyncConflictError"; } }

/** Preserve PostgREST diagnostics when an SDK/network error is a plain object. */
export function cloudErrorMessage(error: unknown): string {
  if (error instanceof Error) return error.message || error.name;
  if (error && typeof error === "object") {
    const value = error as Record<string, unknown>;
    const fields = ["message", "code", "details", "hint", "status", "statusText"]
      .map(key => value[key])
      .filter((item): item is string | number => typeof item === "string" || typeof item === "number")
      .map(String);
    if (fields.length) return [...new Set(fields)].join(" · ");
    try { return JSON.stringify(error); } catch { /* fall through */ }
  }
  return typeof error === "string" && error ? error : "Unknown Supabase error (no response details were provided).";
}

export type GoalContributionOperation = {
  operationId: string;
  goalId: string;
  amount: number;
  date: string;
  accountId?: string;
  transactionId?: string;
  sourceAccountId?: string;
  merchant?: string;
  note?: string;
};

export async function loadCloudState(client: SupabaseClient, userId: string): Promise<FinanceState> {
  const [accounts, categories, transactions, budgets, goals, contributions, debts, debtPayments] = await Promise.all([
    fetchAll(from => client.from("accounts").select("*").eq("user_id", userId).order("id").range(from, from + 999)),
    fetchAll(from => client.from("categories").select("id,name,kind,user_id").or(`user_id.is.null,user_id.eq.${userId}`).order("id").range(from, from + 999)),
    fetchAll(from => client.from("transactions").select("*").eq("user_id", userId).order("transaction_date", { ascending: false }).order("id").range(from, from + 999)),
    fetchAll(from => client.from("budgets").select("*").eq("user_id", userId).order("id").range(from, from + 999)),
    fetchAll(from => client.from("financial_goals").select("*").eq("user_id", userId).order("id").range(from, from + 999)),
    fetchAll(from => client.from("goal_contributions").select("*").eq("user_id", userId).order("id").range(from, from + 999)),
    fetchAll(from => client.from("debt_obligations").select("*").eq("user_id", userId).order("id").range(from, from + 999)),
    fetchAll(from => client.from("debt_payments").select("*").eq("user_id", userId).order("payment_date", { ascending: true }).order("id").range(from, from + 999)),
  ]);
  const categoryName = new Map((categories as CategoryRow[]).map(row => [row.id, row.name]));
  const contributionsByGoal = new Map<string, number>();
  const goalContributions: GoalContribution[] = (contributions as ContributionRow[]).map(row => {
    contributionsByGoal.set(row.goal_id, sumMoney([contributionsByGoal.get(row.goal_id) ?? 0, Number(row.amount)]));
    return { id: row.id, operationId: row.operation_id, goalId: row.goal_id, amount: Number(row.amount), date: row.contributed_at, ...(row.account_id ? { accountId: row.account_id } : {}), ...(row.transaction_id ? { transactionId: row.transaction_id } : {}) };
  });
  const paymentsByDebt = new Map<string, DebtPayment[]>();
  for (const item of debtPayments as DebtPaymentRow[]) paymentsByDebt.set(item.debt_id, [...(paymentsByDebt.get(item.debt_id) ?? []), { id: item.id, operationId: item.operation_id, amount: Number(item.amount), date: item.payment_date, note: item.note ?? "", version: item.version }]);
  return {
    accounts: (accounts as AccountRow[]).map(row => ({ id: row.id, name: row.name, kind: row.account_type, institution: row.institution ?? "", openingBalance: Number(row.opening_balance), createdAt: row.created_at, version: row.version } satisfies Account)),
    transactions: (transactions as TransactionRow[]).map(row => ({ id: row.id, type: transactionType(row.transaction_type), status: row.status, amount: Number(row.amount), category: row.transaction_type === "transfer" || row.transaction_type === "credit_card_payment" ? "Transfer" : (row.category_id ? categoryName.get(row.category_id) : undefined) ?? "Other", accountId: row.account_id, ...(row.destination_account_id ? { destinationId: row.destination_account_id } : {}), merchant: row.merchant ?? "", date: row.transaction_date, note: row.notes ?? row.description ?? "", createdAt: row.created_at, version: row.version } satisfies Transaction)),
    budgets: (budgets as BudgetRow[]).map(row => ({ id: row.id, category: row.name, limit: Number(row.amount), month: row.starts_on.slice(0, 7), version: row.version } satisfies Budget)),
    goals: (goals as GoalRow[]).map(row => ({ id: row.id, name: row.name, target: Number(row.target_amount), saved: contributionsByGoal.get(row.id) ?? 0, due: row.target_date ?? "", version: row.version } satisfies Goal)),
    goalContributions,
    debts: (debts as DebtRow[]).map(row => ({ id: row.id, person: row.person, direction: row.direction, amount: Number(row.amount), remaining: Number(row.remaining), due: row.due_date ?? "", reminder: row.reminder_date ?? "", note: row.note ?? "", createdAt: row.created_at, payments: paymentsByDebt.get(row.id) ?? [], version: row.version } satisfies Debt)),
  };
}

async function fetchAll<T>(page: (from: number) => PromiseLike<{ data: T[] | null; error: unknown }>): Promise<T[]> {
  const rows: T[] = [];
  for (let from = 0; ; from += 1000) {
    const result = await page(from);
    if (result.error) throw result.error;
    const batch = result.data ?? [];
    rows.push(...batch);
    if (batch.length < 1000) return rows;
  }
}

/** Persist one snapshot diff through a single database transaction. */
export async function saveCloudState(client: SupabaseClient, userId: string, before: FinanceState, after: FinanceState) {
  const beforeDebts = new Map(before.debts.map(d => [d.id, d]));
  for (const debt of after.debts) {
    const old = beforeDebts.get(debt.id);
    if (old && (old.remaining !== debt.remaining || JSON.stringify(old.payments) !== JSON.stringify(debt.payments))) {
      throw new Error("Debt repayment changes must use the atomic repayment operation.");
    }
  }
  if (JSON.stringify(before.goalContributions) !== JSON.stringify(after.goalContributions)) {
    throw new Error("Savings contributions must use the atomic contribution operation.");
  }

  const categoryIds = new Map<string, string>();
  const resolve = async (kind: string, name: string) => {
    const key = `${kind}:${name}`;
    if (!categoryIds.has(key)) categoryIds.set(key, await resolveCategoryId(client, userId, kind, name));
    return categoryIds.get(key)!;
  };
  for (const t of after.transactions.filter(t => t.type !== "transfer" && t.type !== "credit_card_payment")) await resolve(t.type === "income" ? "income" : "expense", t.category || "Other");
  for (const b of after.budgets) await resolve("expense", b.category || "Other");

  const snapshot = {
    accounts: buildSyncDelta(before.accounts, after.accounts, a => ({ id: a.id, user_id: userId, name: a.name, account_type: dbAccountType(a.kind), institution: a.institution || null, opening_balance: a.openingBalance, currency: "INR", created_at: a.createdAt })),
    transactions: buildSyncDelta(before.transactions, after.transactions, t => ({
      id: t.id, user_id: userId, transaction_type: t.type, status: t.status ?? "posted", amount: t.amount, currency: "INR", category_id: t.type === "transfer" || t.type === "credit_card_payment" ? null : categoryIds.get(`${t.type === "income" ? "income" : "expense"}:${t.category || "Other"}`) ?? null,
      account_id: t.accountId, destination_account_id: t.destinationId ?? null, merchant: t.merchant || null, transaction_date: t.date,
      notes: t.note || null, created_at: t.createdAt,
    })),
    budgets: buildSyncDelta(before.budgets, after.budgets, b => ({ id: b.id, user_id: userId, name: b.category, category_id: categoryIds.get(`expense:${b.category || "Other"}`) ?? null, amount: b.limit, period: "monthly", starts_on: `${b.month}-01` })),
    financial_goals: buildSyncDelta(before.goals, after.goals, g => ({ id: g.id, user_id: userId, name: g.name, target_amount: g.target, target_date: g.due || null }), (a, b) => a.name === b.name && a.target === b.target && a.due === b.due),
    debt_obligations: buildSyncDelta(before.debts, after.debts, d => ({ id: d.id, user_id: userId, person: d.person, direction: d.direction, amount: d.amount, remaining: d.remaining, due_date: d.due || null, reminder_date: d.reminder || null, note: d.note || null, created_at: d.createdAt })),
  };
  const { error } = await client.rpc("save_finance_state", { p_snapshot: snapshot });
  if (error) throw new Error(`Supabase save failed: ${cloudErrorMessage(error)}`);
  return loadCloudState(client, userId);
}

export function buildSyncDelta<T extends Versioned>(before: T[], after: T[], toRow: (item: T) => WriteRow, same: (a: T, b: T) => boolean = (a, b) => JSON.stringify(a) === JSON.stringify(b)) {
  const old = new Map(before.map(item => [item.id, item]));
  const currentIds = new Set(after.map(item => item.id));
  const writes = after.flatMap(item => {
    const previous = old.get(item.id);
    if (previous && same(previous, item)) return [];
    if (previous && typeof previous.version !== "number") throw new SyncConflictError("Reload before saving a record so its current version can be checked.");
    return [{ ...toRow(item), expected_version: previous?.version ?? null }];
  });
  const deletes = before.filter(item => !currentIds.has(item.id)).map(item => {
    if (typeof item.version !== "number") throw new SyncConflictError("Reload before deleting a record so its current version can be checked.");
    return { id: item.id, version: item.version };
  });
  return { writes, deletes };
}

export async function recordCloudGoalContribution(client: SupabaseClient, operation: GoalContributionOperation) {
  const result = await client.rpc("record_goal_contribution", {
    p_operation_id: operation.operationId,
    p_goal_id: operation.goalId,
    p_amount: operation.amount,
    p_contributed_at: operation.date,
    p_account_id: operation.accountId ?? null,
    p_transaction_id: operation.transactionId ?? null,
    p_source_account_id: operation.sourceAccountId ?? null,
    p_merchant: operation.merchant ?? null,
    p_note: operation.note ?? null,
  });
  if (result.error) throw result.error;
  return result.data as { contribution_id: string; transaction_id: string | null }[];
}

export async function recordCloudDebtPayment(client: SupabaseClient, debtId: string, payment: DebtPayment) {
  const result = await client.rpc("record_debt_payment", { p_debt_id: debtId, p_operation_id: payment.id, p_amount: payment.amount, p_payment_date: payment.date, p_note: payment.note || null });
  if (result.error) throw result.error;
  return result.data as { payment_id: string; remaining: number; debt_version: number; payment_version: number }[];
}

export async function editCloudDebtPayment(client: SupabaseClient, payment: DebtPayment) {
  if (typeof payment.version !== "number") throw new SyncConflictError("Reload before editing this payment to obtain its current version.");
  const result = await client.rpc("edit_debt_payment_v2", { p_payment_id: payment.id, p_expected_version: payment.version, p_amount: payment.amount, p_payment_date: payment.date, p_note: payment.note || null });
  if (result.error) throw result.error;
  const row = (result.data as { remaining: number; debt_version: number; payment_version: number }[] | null)?.[0];
  if (!row) throw new Error("The payment edit response did not include updated database versions.");
  return { remaining: Number(row.remaining), debtVersion: Number(row.debt_version), paymentVersion: Number(row.payment_version) };
}

export async function deleteCloudDebtPayment(client: SupabaseClient, payment: DebtPayment) {
  if (typeof payment.version !== "number") throw new SyncConflictError("Reload before deleting this payment to obtain its current version.");
  const result = await client.rpc("delete_debt_payment_v2", { p_payment_id: payment.id, p_expected_version: payment.version });
  if (result.error) throw result.error;
  const row = (result.data as { remaining: number; debt_version: number }[] | null)?.[0];
  if (!row) throw new SyncConflictError("This payment was already removed. Reload the cloud data to confirm its current balance.");
  return { remaining: Number(row.remaining), debtVersion: Number(row.debt_version) };
}

export async function resetCloudData(client: SupabaseClient) {
  const { error } = await client.rpc("reset_my_finance_data");
  if (error) throw error;
}

async function resolveCategoryId(client: SupabaseClient, userId: string, kind: string, name: string) {
  const { data: own, error: ownError } = await client.from("categories").select("id").eq("user_id", userId).eq("kind", kind).eq("name", name).maybeSingle();
  if (ownError) throw ownError;
  if (own?.id) return own.id as string;
  const { data: global, error: globalError } = await client.from("categories").select("id").is("user_id", null).eq("kind", kind).eq("name", name).maybeSingle();
  if (globalError) throw globalError;
  if (global?.id) return global.id as string;
  const { data: created, error } = await client.from("categories").insert({ user_id: userId, kind, name }).select("id").single();
  if (!error) return created.id as string;
  if (error.code !== "23505") throw error;
  const { data: raced, error: racedError } = await client.from("categories").select("id").eq("user_id", userId).eq("kind", kind).eq("name", name).single();
  if (racedError) throw racedError;
  return raced.id as string;
}

function transactionType(value: string): TxType {
  if (["income", "expense", "transfer", "refund", "credit_card_purchase", "credit_card_payment"].includes(value)) return value as TxType;
  throw new Error(`Unsupported transaction type from Supabase: ${value}. No transaction was discarded.`);
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
