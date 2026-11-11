# EstiMate Phase 1 — Supabase migration

## What this migration does
- Adds the Personal Finance tables.
- Adds owner-scoped foreign keys, indexes, updated_at triggers, and RLS policies.
- Does not alter or delete `projects` or `project_materials`.

## Before applying
1. Back up the current Supabase database.
2. In Supabase SQL Editor, inspect the existing `projects` and `project_materials` schemas and RLS policies.
3. Confirm that `auth.users` is the authentication table used by this project.
4. Review whether any of the new table names already exist.
5. Apply the SQL to a development/staging project first.

## Apply
Open `20261112000100_personal_finance_foundation.sql` and run it in the Supabase SQL Editor, or add it to the project's Supabase migration workflow.

## Verify after applying
- Confirm all nine new tables exist.
- Confirm RLS is enabled on all nine tables.
- Test inserts/selects using two different authenticated accounts.
- Confirm one user cannot read or mutate another user's rows.
- Confirm the existing project dashboard still reads and writes `projects` and `project_materials`.

## Important implementation notes
- Savings contributions are stored separately and are not counted as expense transactions.
- Transactions require an expense category only when `transaction_type = 'expense'`.
- Budget periods store income and saving snapshots so historical plans can remain stable.
- This migration has not been executed against the live Supabase project. It must be reviewed against the actual live schema before production use.
