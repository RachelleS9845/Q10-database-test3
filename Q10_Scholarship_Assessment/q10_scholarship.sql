/* =====================================================================
   ICT371 Advanced Database — Question 10: Scholarship Application Assessment
   DBMS : PostgreSQL 14+ (tested on PostgreSQL 16) with pg_cron
   Rule : qualify only if age 18–25 inclusive AND monthly income <= K3,000
          AND average mark >= 70. Statuses: PENDING, APPROVED, REJECTED.
   ===================================================================== */

DROP SCHEMA IF EXISTS q10_scholarship CASCADE;
CREATE SCHEMA q10_scholarship;
SET search_path TO q10_scholarship, public;

/* ---------------------------------------------------------------------
   (a) DATABASE — tables  [6 marks]
   --------------------------------------------------------------------- */
CREATE TABLE students (
    student_id      SERIAL       PRIMARY KEY,
    student_number  VARCHAR(20)  NOT NULL UNIQUE,
    full_name       VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id      SERIAL        PRIMARY KEY,
    student_id          INTEGER       NOT NULL REFERENCES students(student_id),
    age_at_application  INTEGER       NOT NULL CHECK (age_at_application > 0),
    monthly_income      NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark        NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on        DATE          NOT NULL DEFAULT CURRENT_DATE,
    status              VARCHAR(8)    NOT NULL DEFAULT 'PENDING'
        CONSTRAINT chk_app_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id        SERIAL      PRIMARY KEY,
    application_id  INTEGER     NOT NULL REFERENCES applications(application_id),
    old_status      VARCHAR(8)  NOT NULL,
    new_status      VARCHAR(8)  NOT NULL,
    changed_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

/* ---------------------------------------------------------------------
   (b) FUNCTION fn_scholarship_eligible(p_age, p_income, p_mark)  [6 marks]
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age    INTEGER,
    p_income NUMERIC,
    p_mark   NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SET search_path = q10_scholarship, public
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark are all required' USING ERRCODE = '22023';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive (got %)', p_age USING ERRCODE = '22023';
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income cannot be negative (got %)', p_income USING ERRCODE = '22023';
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100 (got %)', p_mark USING ERRCODE = '22023';
    END IF;

    RETURN p_age BETWEEN 18 AND 25
       AND p_income <= 3000
       AND p_mark   >= 70;
END;
$$;

/* ---------------------------------------------------------------------
   (c) PROCEDURE pr_assess_application(p_application_id)  [8 marks]
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql
SET search_path = q10_scholarship, public
AS $$
DECLARE
    v_app        applications%ROWTYPE;
    v_new_status VARCHAR(8);
BEGIN
    SELECT * INTO v_app
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Application % does not exist', p_application_id USING ERRCODE = 'P0002';
    END IF;

    IF v_app.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % was already assessed (status %)', p_application_id, v_app.status
              USING ERRCODE = 'P0001';
    END IF;

    IF fn_scholarship_eligible(v_app.age_at_application, v_app.monthly_income, v_app.average_mark) THEN
        v_new_status := 'APPROVED';
    ELSE
        v_new_status := 'REJECTED';
    END IF;

    UPDATE applications
    SET    status = v_new_status
    WHERE  application_id = p_application_id;

    RAISE NOTICE 'Application % -> %', p_application_id, v_new_status;
END;
$$;

/* ---------------------------------------------------------------------
   (d) TRIGGER — AFTER UPDATE: audit real status changes  [8 marks]
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION trg_fn_decision_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = q10_scholarship, public
AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (NEW.application_id, OLD.status, NEW.status, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_applications_decision_audit
AFTER UPDATE OF status ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_decision_audit();

/* ---------------------------------------------------------------------
   (a) SEED DATA — 3 students, 6 PENDING applications covering
   qualifying, non-qualifying and BOUNDARY cases.
   --------------------------------------------------------------------- */
INSERT INTO students (student_number, full_name) VALUES
    ('2024030001', 'Mwila Banda'),
    ('2024030002', 'Chanda Phiri'),
    ('2024030003', 'Natasha Zulu');

INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
    (1, 18, 3000.00, 70.00, CURRENT_DATE - 20),  -- 1 all three rules exactly on the boundary -> APPROVED
    (2, 25, 1500.00, 88.50, CURRENT_DATE - 18),  -- 2 upper age boundary                      -> APPROVED
    (2, 26, 1200.00, 91.00, CURRENT_DATE - 15),  -- 3 one year too old                         -> REJECTED
    (2, 22, 3000.01, 80.00, CURRENT_DATE - 12),  -- 4 income 1 ngwee over the limit            -> REJECTED
    (3, 20, 2000.00, 69.99, CURRENT_DATE - 10),  -- 5 mark just below 70                       -> REJECTED
    (3, 17,  900.00, 95.00, CURRENT_DATE - 5);   -- 6 one year too young                       -> REJECTED

SELECT * FROM applications ORDER BY application_id;

/* ---------------------------------------------------------------------
   TESTS for (b), (c), (d)
   --------------------------------------------------------------------- */
SELECT fn_scholarship_eligible(18, 3000, 70)    AS lower_bounds,     -- true
       fn_scholarship_eligible(25, 0, 100)      AS upper_age,        -- true
       fn_scholarship_eligible(26, 1000, 90)    AS too_old,          -- false
       fn_scholarship_eligible(20, 3000.01, 90) AS income_over;      -- false

DO $$
BEGIN
    BEGIN PERFORM fn_scholarship_eligible(NULL, 1000, 80);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'NULL age       -> %', SQLERRM; END;
    BEGIN PERFORM fn_scholarship_eligible(0, 1000, 80);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Age 0          -> %', SQLERRM; END;
    BEGIN PERFORM fn_scholarship_eligible(20, -1, 80);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Negative inc.  -> %', SQLERRM; END;
    BEGIN PERFORM fn_scholarship_eligible(20, 1000, 101);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Mark 101       -> %', SQLERRM; END;
END $$;

-- (c) assess one application manually
CALL pr_assess_application(1);

DO $$
BEGIN
    BEGIN CALL pr_assess_application(1);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Re-assess      -> %', SQLERRM; END;
    BEGIN CALL pr_assess_application(999);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Unknown app    -> %', SQLERRM; END;
END $$;

-- (d) an UPDATE that does not change status writes no audit row
UPDATE applications SET status = status WHERE application_id = 1;
SELECT * FROM decision_audit ORDER BY audit_id;     -- exactly one row (PENDING -> APPROVED)

/* ---------------------------------------------------------------------
   (e) VIEW v_approved_applicants — APPROVED only, no income column  [5 marks]
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number,
       s.full_name,
       a.average_mark,
       a.status
FROM   applications a
JOIN   students s ON s.student_id = a.student_id
WHERE  a.status = 'APPROVED';

/* ---------------------------------------------------------------------
   (f) INDEX — applications by status within a submitted_on range  [5 marks]
   Justification: status is matched with "=" and submitted_on with a range.
   (status, submitted_on) groups all PENDING (or APPROVED...) rows together
   in date order, so "PENDING submitted this month" is one range scan.
   --------------------------------------------------------------------- */
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);
ANALYZE applications;

EXPLAIN
SELECT application_id, student_id, submitted_on
FROM   applications
WHERE  status = 'PENDING'
AND    submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

BEGIN;
SET LOCAL enable_seqscan = off;
EXPLAIN ANALYZE
SELECT application_id, student_id, submitted_on
FROM   applications
WHERE  status = 'PENDING'
AND    submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
COMMIT;

/* ---------------------------------------------------------------------
   (g) SCHEDULED JOB — pr_assess_pending()  [6 marks]
   Query FOR loop over PENDING rows only, each passed to
   pr_assess_application. Completed applications are never selected, so a
   rerun cannot reassess them or create duplicate audit rows.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
SET search_path = q10_scholarship, public
AS $$
DECLARE
    r_app   RECORD;
    v_count INTEGER := 0;
BEGIN
    FOR r_app IN
        SELECT application_id
        FROM   applications
        WHERE  status = 'PENDING'
        ORDER  BY submitted_on, application_id
    LOOP
        CALL pr_assess_application(r_app.application_id);
        v_count := v_count + 1;
    END LOOP;

    RAISE NOTICE 'pr_assess_pending: % application(s) assessed', v_count;
END;
$$;

CALL pr_assess_pending();      -- assesses applications 2..6
CALL pr_assess_pending();      -- rerun: 0 assessed, no new audit rows

SELECT application_id, age_at_application, monthly_income, average_mark, status
FROM applications ORDER BY application_id;
SELECT COUNT(*) AS audit_rows_6 FROM decision_audit;

SELECT * FROM v_approved_applicants ORDER BY student_number;   -- Mwila and Chanda

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q10_assess_pending',
    '0 8 * * 1',                                   -- 08:00 every Monday
    $$CALL q10_scholarship.pr_assess_pending()$$
);

SELECT jobid, jobname, schedule, command, active
FROM cron.job WHERE jobname = 'q10_assess_pending';
