# MyLedger

MyLedger is a responsive personal finance workspace for INR. It supports browser-local transactions when no Supabase configuration is present, and Supabase Auth plus RLS-backed cloud persistence when configured. It starts empty and computes all figures from entries the user adds.

## Current implementation status

- **Phase 1 — Architecture:** Initial entity model, ledger rules, migration, and this implementation checklist are in place.
- **Phase 2 — Foundation:** Next.js App Router, strict TypeScript, responsive navigation, PWA manifest, Supabase SSR clients, email/password authentication, and cookie refresh middleware are in place.
- **Phase 3 — Core finance:** Accounts, income, expenses, refunds, transfers, transaction editing/deletion, month summaries, budgets, goals, and debt/IOU reminders persist locally or to Supabase based on configuration.
- **Phases 4–6:** Recurring bills, receipt storage, CSV import, PDF reports, offline conflict handling, and deployment remain to be implemented.

### Architecture and calculation rules

- The interface is Next.js App Router with client-side finance state and a separate calculation module (`src/lib/finance.ts`). `src/lib/cloud-store.ts` maps the core records to normalized Supabase tables. When Supabase keys are absent, a versioned browser `localStorage` adapter is used.
- A transaction is denominated in INR. Income and refunds increase the selected account; expenses decrease it. A transfer reduces the source and increases the destination by the same amount, and never counts as income or spending.
- Monthly net spending is expenses minus refunds. Monthly savings are income minus expenses plus refunds. Savings rate is derived as savings divided by income only when income is positive.
- Account balances derive from opening balances plus ledger movements. Totals are not separately persisted.
- Supabase Auth owns each cloud row through RLS. Database triggers write signed `account_postings` atomically whenever a transaction is created, edited, or deleted. Transfers create equal and opposite postings. See `supabase/migrations`.

### Entity relationship sketch

```text
auth.users ── profiles / user_settings
    ├── accounts ──< account_postings >── transactions ──< transaction_splits >── categories
    ├── transactions ──< attachments
    ├── budgets >── categories
    ├── recurring_transactions ──< recurring_occurrences >── transactions
    ├── bills
    └── financial_goals ──< goal_contributions
```

## Run locally

1. Install Node.js 20 or newer.
2. Run `pnpm install`.
3. Copy `.env.example` to `.env.local` and add your project URL and publishable key. The app never needs a service-role key.
4. Run `pnpm dev` and open `http://localhost:3000`.

Without Supabase credentials, the local finance workspace runs and saves to the current browser profile. That storage is not encrypted, backed up, or synchronized. For Supabase mode, configure email/password auth and apply the migration before signing in. Existing local records are not automatically imported; export a CSV backup before switching modes.

## Supabase setup

1. Create a Supabase project and enable email authentication.
2. Set `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` in `.env.local`. A legacy anon key is also accepted. Never put a service-role key in this app.
3. Apply all migrations in timestamp order. If this project already has the initial schema and ledger trigger, also run `supabase/migrations/20261101140000_debt_reminders.sql` in the SQL editor to add the debt and repayment tables with owner-only RLS.
4. Configure private Storage bucket policies for owner-scoped receipt folders before enabling attachments.
5. Add `http://localhost:3000/**` and the production URL to Auth redirect URLs. Require email verification for production sign-up.
6. Sign up in MyLedger. In hosted Supabase, verify your email before signing in.

## Publish a public URL with Vercel

The repository currently has no commit or Git remote, so publish it through a private GitHub repository first:

1. Create an empty **private** GitHub repository.
2. From this project folder, commit and push the app:

   ```powershell
   git add .
   git commit -m "Build MyLedger finance app"
   git branch -M main
   git remote add origin https://github.com/YOUR_ACCOUNT/YOUR_REPOSITORY.git
   git push -u origin main
   ```

   `.env.local` is ignored by Git. Keep the real Supabase values there locally; commit only `.env.example`.
3. In Vercel, choose **Add New → Project**, import the GitHub repository, and keep the detected Next.js settings. Add these environment variables for **Production** (and Preview if you use preview deployments):
   - `NEXT_PUBLIC_SUPABASE_URL`
   - `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`
4. Deploy. Vercel gives the app an HTTPS `*.vercel.app` URL. Share that URL and sign in from your laptop or phone.
5. In Supabase **Authentication → URL Configuration**, set **Site URL** to the production URL and add it to **Redirect URLs**. Also allow `http://localhost:3000/**` for local development. For email confirmations to work, Supabase must allow the origin used by MyLedger. The Site URL and redirect allow-list are documented by [Supabase](https://supabase.com/docs/guides/auth/redirect-urls).
6. If you change Vercel environment variables, redeploy; Vercel applies them to new deployments, not already-built ones. See [Vercel environment variables](https://vercel.com/docs/environment-variables).

You can use the same HTTPS URL on Android Chrome or iPhone Safari and bookmark it or add it to the home screen. MyLedger's service worker is network-only, so an installed shortcut still needs an internet connection. A custom domain is optional; Vercel assigns a `vercel.app` domain by default. See [Vercel domains](https://vercel.com/docs/domains/working-with-domains).

## Checks

- `pnpm test` runs financial calculation unit tests.
- `pnpm build` creates a production build.
- There is no Playwright end-to-end suite yet. The Supabase project connection, migration deployment, email delivery, and RLS isolation have not been verified in this workspace.

## Security and limitations

- The browser-local version is single-browser and has no multi-device synchronization, login, encryption-at-rest guarantee, or server backup.
- Supabase mode uses owner-based RLS and does not expose a service-role key. A security review and adversarial isolation tests are still required before production.
- Debt reminders appear in the app and can send browser notifications when MyLedger is open. The browser will ask permission; scheduled alerts while the app is closed and email reminders are not configured.
- No credential, hosted database, PDF exporter, attachment flow, scheduled reminders, or production deployment is supplied.
- Core totals and monthly aggregates use integer paise in the client and PostgreSQL `numeric` in the database.

## Development checklist

- [x] Inspect environment and identify empty workspace.
- [x] Choose product label from final brief instruction: MyLedger.
- [x] Document architecture, route surface, ledger rules, and ER sketch.
- [x] Add initial normalized Postgres schema and owner RLS policies.
- [x] Build responsive dashboard and core local finance flows.
- [x] Add finance calculation tests.
- [x] Implement Supabase email/password auth and RLS-backed core cloud persistence.
- [x] Add trigger-maintained signed account postings for posted transactions.
- [ ] Add account reconciliation, credit card liability rules, split transactions, partial refunds, and audit trail.
- [ ] Add recurring bills, attachments, import validation, PDF exports, advanced analytics, and net-worth/liability history.
- [x] Add PWA manifest/icon and a network-only service worker (no sensitive response caching).
- [ ] Add offline queue/conflict behavior with safe synchronization.
- [ ] Add authenticated integration and Playwright workflows, isolation checks, and production deployment docs.
