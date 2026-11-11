-- EstiMate Personal Finance Foundation
-- Additive migration: does not alter or delete existing project budgeting tables.
-- Review against the live Supabase schema before applying to production.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Shared updated_at trigger
-- ---------------------------------------------------------------------------
create or replace function public.estimate_set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. Financial profile: one profile per authenticated user
-- ---------------------------------------------------------------------------
create table if not exists public.financial_profiles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  user_type text not null check (user_type in ('student', 'worker')),
  currency text not null default 'IDR' check (char_length(currency) = 3),
  timezone text not null default 'Asia/Jakarta',
  onboarding_completed boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint financial_profiles_id_user_id_key unique (id, user_id)
);

-- ---------------------------------------------------------------------------
-- 2. Income sources: allowance, salary, freelance, business, etc.
-- ---------------------------------------------------------------------------
create table if not exists public.income_sources (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  amount numeric(15,2) not null check (amount >= 0),
  frequency text not null check (
    frequency in ('weekly', 'biweekly', 'monthly', 'irregular')
  ),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint income_sources_id_user_id_key unique (id, user_id)
);

-- ---------------------------------------------------------------------------
-- 3. Mindset assessment answers. JSONB allows multiple answer formats.
-- ---------------------------------------------------------------------------
create table if not exists public.assessment_responses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  assessment_version text not null default 'v1',
  question_key text not null,
  answer jsonb not null,
  created_at timestamptz not null default now(),
  constraint assessment_responses_user_question_key
    unique (user_id, assessment_version, question_key)
);

-- ---------------------------------------------------------------------------
-- 4. Budget periods: immutable planning snapshots by period
-- ---------------------------------------------------------------------------
create table if not exists public.budget_periods (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  period_start date not null,
  period_end date not null,
  income_snapshot numeric(15,2) not null check (income_snapshot >= 0),
  saving_target numeric(15,2) not null default 0 check (saving_target >= 0),
  spending_limit numeric(15,2) not null check (spending_limit >= 0),
  status text not null default 'draft'
    check (status in ('draft', 'active', 'closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint budget_periods_date_order check (period_start <= period_end),
  constraint budget_periods_saving_within_income
    check (saving_target <= income_snapshot),
  constraint budget_periods_id_user_id_key unique (id, user_id)
);

create index if not exists budget_periods_user_dates_idx
  on public.budget_periods (user_id, period_start desc, period_end);

-- ---------------------------------------------------------------------------
-- 5. Expense categories: user-owned, customizable needs/wants categories
-- ---------------------------------------------------------------------------
create table if not exists public.expense_categories (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  category_type text not null check (category_type in ('needs', 'wants')),
  is_default boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint expense_categories_id_user_id_key unique (id, user_id),
  constraint expense_categories_user_name_key unique (user_id, name)
);

create index if not exists expense_categories_user_active_idx
  on public.expense_categories (user_id, is_active);

-- ---------------------------------------------------------------------------
-- 6. Saving goals
-- ---------------------------------------------------------------------------
create table if not exists public.saving_goals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  goal_name text not null check (length(trim(goal_name)) > 0),
  target_amount numeric(15,2) not null check (target_amount > 0),
  target_date date,
  status text not null default 'active'
    check (status in ('active', 'completed', 'paused')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint saving_goals_id_user_id_key unique (id, user_id)
);

-- ---------------------------------------------------------------------------
-- 7. Budget allocations: category-level plans per budget period
-- ---------------------------------------------------------------------------
create table if not exists public.budget_allocations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  budget_period_id uuid not null,
  category_id uuid not null,
  planned_amount numeric(15,2) not null check (planned_amount >= 0),
  allocation_percentage numeric(5,2)
    check (allocation_percentage between 0 and 100),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint budget_allocations_period_owner_fk
    foreign key (budget_period_id, user_id)
    references public.budget_periods(id, user_id) on delete cascade,
  constraint budget_allocations_category_owner_fk
    foreign key (category_id, user_id)
    references public.expense_categories(id, user_id) on delete restrict,
  constraint budget_allocations_period_category_key
    unique (budget_period_id, category_id)
);

create index if not exists budget_allocations_user_period_idx
  on public.budget_allocations (user_id, budget_period_id);

-- ---------------------------------------------------------------------------
-- 8. Transactions: income and expense. Savings are NOT expenses.
-- ---------------------------------------------------------------------------
create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  budget_period_id uuid,
  category_id uuid,
  income_source_id uuid,
  transaction_type text not null check (transaction_type in ('income', 'expense')),
  amount numeric(15,2) not null check (amount > 0),
  description text,
  transaction_date timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint transactions_period_owner_fk
    foreign key (budget_period_id, user_id)
    references public.budget_periods(id, user_id) on delete restrict,
  constraint transactions_category_owner_fk
    foreign key (category_id, user_id)
    references public.expense_categories(id, user_id) on delete restrict,
  constraint transactions_income_source_owner_fk
    foreign key (income_source_id, user_id)
    references public.income_sources(id, user_id) on delete restrict,
  constraint transactions_expense_category_required
    check (transaction_type <> 'expense' or category_id is not null)
);

create index if not exists transactions_user_date_idx
  on public.transactions (user_id, transaction_date desc);

create index if not exists transactions_user_period_type_idx
  on public.transactions (user_id, budget_period_id, transaction_type);

create index if not exists transactions_user_category_idx
  on public.transactions (user_id, category_id);

-- ---------------------------------------------------------------------------
-- 9. Savings contributions: separate from expense transactions
-- ---------------------------------------------------------------------------
create table if not exists public.savings_contributions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  saving_goal_id uuid not null,
  budget_period_id uuid,
  amount numeric(15,2) not null check (amount > 0),
  contribution_date timestamptz not null default now(),
  description text,
  created_at timestamptz not null default now(),
  constraint savings_contributions_goal_owner_fk
    foreign key (saving_goal_id, user_id)
    references public.saving_goals(id, user_id) on delete cascade,
  constraint savings_contributions_period_owner_fk
    foreign key (budget_period_id, user_id)
    references public.budget_periods(id, user_id) on delete restrict
);

create index if not exists savings_contributions_user_date_idx
  on public.savings_contributions (user_id, contribution_date desc);

create index if not exists savings_contributions_goal_idx
  on public.savings_contributions (user_id, saving_goal_id);

-- ---------------------------------------------------------------------------
-- Updated-at triggers
-- ---------------------------------------------------------------------------
drop trigger if exists financial_profiles_set_updated_at on public.financial_profiles;
create trigger financial_profiles_set_updated_at
before update on public.financial_profiles
for each row execute function public.estimate_set_updated_at();

drop trigger if exists income_sources_set_updated_at on public.income_sources;
create trigger income_sources_set_updated_at
before update on public.income_sources
for each row execute function public.estimate_set_updated_at();

drop trigger if exists budget_periods_set_updated_at on public.budget_periods;
create trigger budget_periods_set_updated_at
before update on public.budget_periods
for each row execute function public.estimate_set_updated_at();

drop trigger if exists expense_categories_set_updated_at on public.expense_categories;
create trigger expense_categories_set_updated_at
before update on public.expense_categories
for each row execute function public.estimate_set_updated_at();

drop trigger if exists saving_goals_set_updated_at on public.saving_goals;
create trigger saving_goals_set_updated_at
before update on public.saving_goals
for each row execute function public.estimate_set_updated_at();

drop trigger if exists budget_allocations_set_updated_at on public.budget_allocations;
create trigger budget_allocations_set_updated_at
before update on public.budget_allocations
for each row execute function public.estimate_set_updated_at();

drop trigger if exists transactions_set_updated_at on public.transactions;
create trigger transactions_set_updated_at
before update on public.transactions
for each row execute function public.estimate_set_updated_at();

-- ---------------------------------------------------------------------------
-- Row Level Security: users can only access their own financial records.
-- Existing project tables and their policies are intentionally untouched.
-- ---------------------------------------------------------------------------
alter table public.financial_profiles enable row level security;
alter table public.income_sources enable row level security;
alter table public.assessment_responses enable row level security;
alter table public.budget_periods enable row level security;
alter table public.expense_categories enable row level security;
alter table public.saving_goals enable row level security;
alter table public.budget_allocations enable row level security;
alter table public.transactions enable row level security;
alter table public.savings_contributions enable row level security;

create policy "Users manage own financial profile"
  on public.financial_profiles for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "Users manage own income sources"
  on public.income_sources for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "Users manage own assessment responses"
  on public.assessment_responses for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "Users manage own budget periods"
  on public.budget_periods for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "Users manage own expense categories"
  on public.expense_categories for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "Users manage own saving goals"
  on public.saving_goals for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "Users manage own budget allocations"
  on public.budget_allocations for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "Users manage own transactions"
  on public.transactions for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "Users manage own savings contributions"
  on public.savings_contributions for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- Grant authenticated users table privileges; RLS remains the row-level guard.
grant select, insert, update, delete on
  public.financial_profiles,
  public.income_sources,
  public.assessment_responses,
  public.budget_periods,
  public.expense_categories,
  public.saving_goals,
  public.budget_allocations,
  public.transactions,
  public.savings_contributions
to authenticated;

-- No grants are added for anon.
