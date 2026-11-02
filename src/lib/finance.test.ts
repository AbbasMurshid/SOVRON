import { describe, expect, it } from "vitest";
import { accountBalances, FinanceState, monthSummary, runDiagnostics, sumMoney, validateTransaction, validateTransfer } from "./finance";

const base: FinanceState = {
  accounts: [
    { id: "bank", name: "Bank", kind: "Savings account", institution: "", openingBalance: 10000, createdAt: "" },
    { id: "cash", name: "Cash", kind: "Cash wallet", institution: "", openingBalance: 500, createdAt: "" },
  ],
  transactions: [
    { id: "i", type: "income", amount: 50000, category: "Salary", accountId: "bank", merchant: "Salary", date: "2026-11-01", note: "", createdAt: "" },
    { id: "e", type: "expense", amount: 2500, category: "Food & dining", accountId: "bank", merchant: "Market", date: "2026-11-02", note: "", createdAt: "" },
    { id: "r", type: "refund", amount: 200, category: "Shopping", accountId: "bank", merchant: "Return", date: "2026-11-03", note: "", createdAt: "" },
    { id: "t", type: "transfer", amount: 1000, category: "Transfer", accountId: "bank", destinationId: "cash", merchant: "Transfer", date: "2026-11-04", note: "", createdAt: "" },
    { id: "old", type: "expense", amount: 500, category: "Travel", accountId: "cash", merchant: "Bus", date: "2026-10-31", note: "", createdAt: "" },
  ], budgets: [], goals: [], goalContributions: [], debts: [],
};

describe("financial calculations", () => {
  it("keeps transfers out of income and spending", () => expect(monthSummary(base, "2026-11")).toMatchObject({ income: 50000, expenses: 2500, refunds: 200, netSpend: 2300, saved: 47700, count: 4 }));
  it("applies transfers once to each account and refunds to balance", () => expect(accountBalances(base)).toEqual({ bank: 56700, cash: 1000 }));
  it("returns zero savings rate inputs when there is no income", () => expect(monthSummary({ ...base, transactions: [] }, "2026-11")).toMatchObject({ income: 0, expenses: 0, saved: 0 }));
  it("isolates dates at month boundaries", () => expect(monthSummary(base, "2026-10")).toMatchObject({ expenses: 500, count: 1 }));
  it("adds fractional rupees without floating point drift", () => expect(sumMoney([0.1, 0.2, 0.05, 0.05])).toBe(0.4));
  it("blocks transfers that exceed the available source balance", () => expect(validateTransfer(base, "bank", "cash", 999999).ok).toBe(false));
  it("accepts a funded transfer and rejects an invalid destination", () => {
    expect(validateTransfer(base, "bank", "cash", 100).ok).toBe(true);
    expect(validateTransfer(base, "bank", "missing", 100).ok).toBe(false);
  });
  it("reports a negative asset account during diagnostics", () => {
    const state = { ...base, transactions: [...base.transactions, { id: "overdraw", type: "expense" as const, amount: 5000, category: "Other", accountId: "cash", merchant: "", date: "2026-11-05", note: "", createdAt: "" }] };
    expect(runDiagnostics(state).find(check => check.name === "Transfer balances")?.passed).toBe(false);
  });
  it("preserves negative credit card balances for purchases and payments", () => {
    const state: FinanceState = { ...base, accounts: [...base.accounts, { id: "card", name: "Card", kind: "Credit card", institution: "", openingBalance: -1200, createdAt: "" }], transactions: [
      { id: "purchase", type: "credit_card_purchase", amount: 250, category: "Food & dining", accountId: "card", merchant: "Cafe", date: "2026-11-05", note: "", createdAt: "" },
      { id: "payment", type: "credit_card_payment", amount: 400, category: "Transfer", accountId: "bank", destinationId: "card", merchant: "Card bill", date: "2026-11-06", note: "", createdAt: "" },
      ...base.transactions,
    ] };
    expect(accountBalances(state)).toMatchObject({ card: -1050, bank: 56300 });
    expect(monthSummary(state, "2026-11")).toMatchObject({ expenses: 2750, count: 6 });
  });
  it("does not include voided transactions in balances or monthly totals", () => {
    const state: FinanceState = { ...base, transactions: [...base.transactions, { id: "void", type: "expense", status: "voided", amount: 9999, category: "Other", accountId: "bank", merchant: "Voided", date: "2026-11-07", note: "", createdAt: "" }] };
    expect(accountBalances(state)).toEqual(accountBalances(base));
    expect(monthSummary(state, "2026-11")).toEqual(monthSummary(base, "2026-11"));
  });
  it("blocks an asset expense that would overdraw its account", () => expect(validateTransaction(base, { type: "expense", sourceId: "cash", amount: 1001 })).toMatchObject({ ok: false }));
  it("requires a card account for card purchases and a card destination for payments", () => {
    const state: FinanceState = { ...base, accounts: [...base.accounts, { id: "card", name: "Card", kind: "Credit card", institution: "", openingBalance: -100, createdAt: "" }] };
    expect(validateTransaction(state, { type: "credit_card_purchase", sourceId: "bank", amount: 10 }).ok).toBe(false);
    expect(validateTransaction(state, { type: "credit_card_payment", sourceId: "bank", destinationId: "cash", amount: 10 }).ok).toBe(false);
    expect(validateTransaction(state, { type: "credit_card_payment", sourceId: "bank", destinationId: "card", amount: 10 }).ok).toBe(true);
  });
});
