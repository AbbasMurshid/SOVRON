export type TxType = "income" | "expense" | "transfer" | "refund" | "credit_card_purchase" | "credit_card_payment";
export type Account = { id: string; name: string; kind: string; institution: string; openingBalance: number; createdAt: string; version?: number };
export type Transaction = { id: string; type: TxType; status?: "posted" | "voided"; amount: number; category: string; accountId: string; destinationId?: string; merchant: string; date: string; note: string; createdAt: string; version?: number };
export type Budget = { id: string; category: string; limit: number; month: string; version?: number };
export type Goal = { id: string; name: string; target: number; saved: number; due: string; version?: number };
export type GoalContribution = { id: string; operationId?: string; goalId: string; amount: number; date: string; accountId?: string; transactionId?: string };
export type DebtDirection = "i_owe" | "owed_to_me";
export type DebtPayment = { id: string; operationId?: string; amount: number; date: string; note: string; version?: number };
export type Debt = { id: string; person: string; direction: DebtDirection; amount: number; remaining: number; due: string; reminder: string; note: string; createdAt: string; payments: DebtPayment[]; version?: number };
export type FinanceState = { accounts: Account[]; transactions: Transaction[]; budgets: Budget[]; goals: Goal[]; goalContributions: GoalContribution[]; debts: Debt[] };
export const EMPTY_STATE: FinanceState = { accounts: [], transactions: [], budgets: [], goals: [], goalContributions: [], debts: [] };
export const CATEGORIES = ["Food & dining", "Transport", "Shopping", "Bills & utilities", "Health", "Entertainment", "Education", "Travel", "Salary", "Freelance", "Other"];

// Keep monetary arithmetic in integer paise; convert to rupees only at the UI boundary.
export const toPaise = (rupees: number) => Math.round((rupees + Number.EPSILON) * 100);
export const fromPaise = (paise: number) => paise / 100;
export function sumMoney(values: number[]) { return fromPaise(values.reduce((total, value) => total + toPaise(value), 0)); }

export function accountBalances(state: FinanceState): Record<string, number> {
  const balances: Record<string, number> = Object.fromEntries(state.accounts.map(a => [a.id, toPaise(a.openingBalance)]));
  for (const t of state.transactions) {
    if ((t.status ?? "posted") !== "posted") continue;
    if (t.type === "income" || t.type === "refund") balances[t.accountId] = (balances[t.accountId] ?? 0) + toPaise(t.amount);
    if (t.type === "expense" || t.type === "credit_card_purchase") balances[t.accountId] = (balances[t.accountId] ?? 0) - toPaise(t.amount);
    if (t.type === "transfer" || t.type === "credit_card_payment") {
      balances[t.accountId] = (balances[t.accountId] ?? 0) - toPaise(t.amount);
      if (t.destinationId) balances[t.destinationId] = (balances[t.destinationId] ?? 0) + toPaise(t.amount);
    }
  }
  for (const [id, balance] of Object.entries(balances)) balances[id] = fromPaise(balance);
  return balances;
}

export function monthSummary(state: FinanceState, month: string) {
  const rows = state.transactions.filter(t => t.date.startsWith(month) && (t.status ?? "posted") === "posted");
  const income = sumMoney(rows.filter(t => t.type === "income").map(t => t.amount));
  const expenses = sumMoney(rows.filter(t => t.type === "expense" || t.type === "credit_card_purchase").map(t => t.amount));
  const refunds = sumMoney(rows.filter(t => t.type === "refund").map(t => t.amount));
  const netSpend = fromPaise(toPaise(expenses) - toPaise(refunds));
  const saved = fromPaise(toPaise(income) - toPaise(expenses) + toPaise(refunds));
  return { income, expenses, refunds, netSpend, saved, count: rows.length };
}

export function validateTransfer(state: FinanceState, sourceId: string, destinationId: string, amount: number) {
  return validateTransaction(state, { type: "transfer", sourceId, destinationId, amount });
}

export function validateTransaction(state: FinanceState, input: { type: TxType; sourceId: string; destinationId?: string; amount: number }) {
  const { type, sourceId, destinationId, amount } = input;
  const source = state.accounts.find(account => account.id === sourceId);
  const destination = destinationId ? state.accounts.find(account => account.id === destinationId) : undefined;
  if (!source) return { ok: false, available: 0, message: "Choose an account." };
  const sourceKind = source.kind.toLowerCase();
  const sourceIsCard = sourceKind.includes("card");
  const sourceIsLiability = sourceIsCard || sourceKind.includes("liability");
  const isAsset = (account: Account) => !account.kind.toLowerCase().includes("card") && !account.kind.toLowerCase().includes("liability");
  const available = accountBalances(state)[sourceId] ?? 0;
  if (!Number.isFinite(amount) || amount <= 0) return { ok: false, available, message: "Enter an amount greater than zero." };
  const twoSided = type === "transfer" || type === "credit_card_payment";
  if (twoSided && !destinationId) return { ok: false, available, message: "Choose a destination account." };
  if (!twoSided && destinationId) return { ok: false, available, message: "This transaction type cannot have a destination account." };
  if (type === "transfer" || type === "credit_card_payment") {
    if (!destination || source.id === destination.id) return { ok: false, available, message: "Choose a different destination account." };
    if (!isAsset(source)) return { ok: false, available, message: "Transfers must start from a cash or asset account." };
    if (type === "transfer" && !isAsset(destination)) return { ok: false, available, message: "Choose another cash or asset account. Use Credit card payment for card bills." };
    if (type === "credit_card_payment" && !destination.kind.toLowerCase().includes("card")) return { ok: false, available, message: "Choose a credit card as the payment destination." };
    if (toPaise(amount) > toPaise(available)) return { ok: false, available, message: `Only ${inr(Math.max(0, available))} is available in this account.` };
  } else if (type === "credit_card_purchase") {
    if (!sourceIsCard) return { ok: false, available, message: "Choose a credit card account for a card purchase." };
  } else if (type === "income" && sourceIsLiability) {
    return { ok: false, available, message: "Income must be deposited into a cash or asset account." };
  } else if (type === "refund" && sourceKind.includes("liability") && !sourceIsCard) {
    return { ok: false, available, message: "Refunds must post to an asset or credit card account." };
  } else if (type === "expense") {
    if (sourceIsLiability) return { ok: false, available, message: "Choose an asset account or select Credit card purchase." };
    if (toPaise(amount) > toPaise(available)) return { ok: false, available, message: `This expense would exceed the ${source.name} balance (${inr(Math.max(0, available))} available).` };
  }
  return { ok: true, available, message: "" };
}

export type Diagnostic = { name: string; passed: boolean; detail: string };
export function runDiagnostics(state: FinanceState): Diagnostic[] {
  const accountIds = new Set(state.accounts.map(a => a.id));
  const duplicateAccountIds = accountIds.size !== state.accounts.length;
  const duplicateTransactionIds = new Set(state.transactions.map(t => t.id)).size !== state.transactions.length;
  const invalidAmounts = state.transactions.some(t => !Number.isFinite(t.amount) || toPaise(t.amount) <= 0);
  const accountById = new Map(state.accounts.map(account => [account.id, account]));
  const badReferences = state.transactions.some(t => {
    const source = accountById.get(t.accountId); const destination = t.destinationId ? accountById.get(t.destinationId) : undefined;
    const sourceKind = source?.kind.toLowerCase() ?? ""; const destinationKind = destination?.kind.toLowerCase() ?? "";
    const sourceLiability = sourceKind.includes("card") || sourceKind.includes("liability");
    const destinationAsset = destination && !destinationKind.includes("card") && !destinationKind.includes("liability");
    const accountTypeMismatch = (t.type === "income" || t.type === "expense" || t.type === "transfer") && sourceLiability
      || t.type === "credit_card_purchase" && !sourceKind.includes("card")
      || t.type === "credit_card_payment" && (sourceLiability || !destinationKind.includes("card"))
      || t.type === "transfer" && !destinationAsset
      || t.type === "refund" && sourceKind.includes("liability") && !sourceKind.includes("card");
    return !source || ((t.type === "transfer" || t.type === "credit_card_payment") && (!destination || t.destinationId === t.accountId))
      || ((t.type === "income" || t.type === "expense" || t.type === "refund" || t.type === "credit_card_purchase") && Boolean(t.destinationId))
      || accountTypeMismatch;
  });
  const accountBalance = accountBalances(state);
  const overdraft = state.accounts.some(a => !a.kind.toLowerCase().includes("liability") && !a.kind.toLowerCase().includes("card") && toPaise(accountBalance[a.id] ?? 0) < 0);
  const invalidGoals = state.goals.some(g => !Number.isFinite(g.target) || g.target <= 0 || !Number.isFinite(g.saved) || g.saved < 0 || !g.name.trim());
  const invalidDebts = (state.debts ?? []).some(d => {
    const invalidAmounts = !Number.isFinite(d.amount) || d.amount <= 0 || !Number.isFinite(d.remaining) || d.remaining < 0 || toPaise(d.remaining) > toPaise(d.amount);
    const invalidPayments = (d.payments ?? []).some(p => !Number.isFinite(p.amount) || p.amount <= 0 || !/^\d{4}-\d{2}-\d{2}$/.test(p.date)) || toPaise(sumMoney((d.payments ?? []).map(p => p.amount))) !== toPaise(d.amount - d.remaining);
    const invalidDates = (d.due && !/^\d{4}-\d{2}-\d{2}$/.test(d.due)) || (d.reminder && !/^\d{4}-\d{2}-\d{2}$/.test(d.reminder)) || (d.due && d.reminder && d.reminder > d.due);
    return !d.person.trim() || invalidAmounts || invalidPayments || invalidDates || !["i_owe", "owed_to_me"].includes(d.direction);
  });
  const orphanedBudgets = state.budgets.some(b => !b.category.trim() || !Number.isFinite(b.limit) || b.limit <= 0 || !/^\d{4}-\d{2}$/.test(b.month));
  const duplicateBudgets = new Set(state.budgets.map(b => `${b.month}:${b.category}`)).size !== state.budgets.length;
  const checks: Diagnostic[] = [
    { name: "Account identifiers", passed: !duplicateAccountIds, detail: duplicateAccountIds ? "Duplicate account IDs found." : `${state.accounts.length} account(s) checked.` },
    { name: "Transaction identifiers", passed: !duplicateTransactionIds, detail: duplicateTransactionIds ? "Duplicate transaction IDs found." : `${state.transactions.length} transaction(s) checked.` },
    { name: "Transaction amounts", passed: !invalidAmounts, detail: invalidAmounts ? "A transaction has an invalid amount." : "All transaction amounts are positive and finite." },
    { name: "Account references", passed: !badReferences, detail: badReferences ? "A transaction points to a missing or invalid account." : "All transaction accounts exist." },
    { name: "Transfer balances", passed: !overdraft, detail: overdraft ? "An asset account has a negative balance; review its transfers and expenses." : "No asset account has a negative balance." },
    { name: "Budgets", passed: !orphanedBudgets && !duplicateBudgets, detail: orphanedBudgets ? "A budget has invalid details." : duplicateBudgets ? "More than one budget exists for a category and month." : `${state.budgets.length} budget(s) checked.` },
    { name: "Savings goals", passed: !invalidGoals, detail: invalidGoals ? "A goal has invalid target or saved amounts." : `${state.goals.length} goal(s) checked.` },
    { name: "Debt and money owed", passed: !invalidDebts, detail: invalidDebts ? "An obligation has invalid person, direction, or amount." : `${(state.debts ?? []).length} obligation(s) checked.` },
  ];
  return checks;
}

export const inr = (n: number) => new Intl.NumberFormat("en-IN", { style: "currency", currency: "INR", maximumFractionDigits: 0 }).format(n);
export const makeId = () => typeof crypto !== "undefined" && "randomUUID" in crypto ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(36).slice(2)}`;
