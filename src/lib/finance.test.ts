import { describe, expect, it } from "vitest";
import { accountBalances, FinanceState, monthSummary, runDiagnostics, sumMoney, validateTransfer } from "./finance";

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
  ], budgets: [], goals: [], debts: [],
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
});
