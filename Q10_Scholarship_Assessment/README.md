# Question 10 — Scholarship Application Assessment

**Script:** [`q10_scholarship.sql`](q10_scholarship.sql) · **Schema:** `q10_scholarship` · **DBMS:** PostgreSQL 14+ with pg_cron

## How to run

pgAdmin: open the Query Tool, open `q10_scholarship.sql` and press **F5**. Results appear in *Data Output*; the test messages (`RAISE NOTICE`) appear in *Messages*.

```bash
psql -d ict371 -f q10_scholarship.sql
```

The script drops and recreates the `q10_scholarship` schema, so it can be run as many times as you like. Part (g) needs pg_cron (setup steps are in the [main README](../README.md#setting-up-pg_cron-part-g)).

## What each part does

| Part | Object | How it meets the requirement |
|------|--------|------------------------------|
| (a) Database & seed [6] | `students`, `applications`, `decision_audit` | `age > 0`, `income >= 0`, `mark BETWEEN 0 AND 100`, status CHECK. Six PENDING applications across three students, including **boundary** cases: 18 / K3 000 / 70 (qualifies), age 25 (qualifies), age 26, income K3 000.01, mark 69.99 and age 17 (all fail). |
| (b) Function [6] | `fn_scholarship_eligible(p_age, p_income, p_mark)` | `age BETWEEN 18 AND 25 AND income <= 3000 AND mark >= 70`. Raises an error for NULL input, age ≤ 0, negative income, or a mark outside 0–100. |
| (c) Procedure [8] | `pr_assess_application(p_application_id)` | Requires an existing PENDING application (locked `FOR UPDATE`), calls the function and sets APPROVED or REJECTED. Raises a clear error for an unknown or already-assessed application. |
| (d) Trigger [8] | `trg_applications_decision_audit` (AFTER UPDATE OF status) | `WHEN (OLD.status IS DISTINCT FROM NEW.status)` logs old status, new status and a timestamp. `SET status = status` writes nothing. |
| (e) View [5] | `v_approved_applicants` | Student number, name, average mark and status for APPROVED rows only. `monthly_income` is deliberately left out. |
| (f) Index [5] | `idx_applications_status_submitted (status, submitted_on)` | Status (=) first, then submitted date (range), so 'PENDING applications this month' is one range scan. |
| (g) Job [6] | `pr_assess_pending()` + cron `0 8 * * 1` | A query FOR loop selects **only PENDING** rows and CALLs `pr_assess_application` for each. A rerun finds nothing to do, so there is no reassessment and no duplicate audit rows. The job runs every Monday at 08:00. |

## Expected results (verified on PostgreSQL 16)

Applications 1 and 2 are APPROVED, 3–6 REJECTED. The rerun assesses 0. `decision_audit` holds exactly 6 rows. The view shows Mwila and Chanda.

Dates are written relative to `CURRENT_DATE`, so the views and summaries show data whenever the script is run.
