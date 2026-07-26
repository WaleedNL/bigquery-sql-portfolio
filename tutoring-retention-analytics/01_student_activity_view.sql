/* ============================================================
   Tutoring Retention Analytics — Layer 1
   Student Activity & Lifetime Value (monthly view)
   ------------------------------------------------------------
   Author:  Waleed Jawaid | Data Specialist
   Tool:    Google BigQuery (Standard SQL)

   Purpose:
     Produces one row per student per month, flagging whether
     that student was active in that month and carrying their
     lifetime and monthly revenue.

   Key challenges solved:
     - Students live in the CRM; invoices live in the accounting
       system. There is no shared key, so the two are bridged on
       a normalised email address.
     - A contact can match multiple company records; ROW_NUMBER()
       deduplicates to one company per student.
     - Source data has no "active" flag at all. Activity is
       defined here as: an invoice exists within the last 42 days
       relative to the month being evaluated.
     - Using LEAST(month_end, CURRENT_DATE) as the reference date
       means historic months evaluate against their own end date
       while the current month evaluates against today.

   Output:
     One row per student per calendar month, with location,
     lifetime value, monthly revenue and an activity flag —
     ready to power retention KPIs in a BI tool.
   ============================================================ */

WITH
  -- CRM contacts joined to their location custom field
  students_raw AS (
    SELECT
      c.id AS contact_id,
      c.email,
      cfv.value AS location_name,
      COALESCE(cfv.u_date, cfv.c_date) AS cf_updated_at
    FROM `analytics-prod.crm.contact` c
    LEFT JOIN `analytics-prod.crm.contact_custom_field_value` cfv
      ON c.id = CAST(cfv.contact AS INT64)
     AND cfv.custom_field_id = '7'
  ),

  -- Keep only the most recently updated location per contact
  students AS (
    SELECT
      contact_id,
      email,
      INITCAP(COALESCE(location_name, 'Unknown')) AS location_name
    FROM students_raw
    QUALIFY ROW_NUMBER() OVER (
      PARTITION BY contact_id
      ORDER BY cf_updated_at DESC NULLS LAST
    ) = 1
  ),

  -- Month spine: every student is evaluated against every month
  calendar AS (
    SELECT d AS date_date
    FROM UNNEST(GENERATE_DATE_ARRAY(
      DATE '2015-01-01',
      DATE_ADD(DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL 5 YEAR),
      INTERVAL 1 MONTH
    )) AS d
  ),

  -- Bridge CRM → accounting on normalised email, one company per student
  student_company AS (
    SELECT contact_id, location_name, companyid
    FROM (
      SELECT
        s.contact_id,
        s.location_name,
        xc.companyid,
        ROW_NUMBER() OVER (
          PARTITION BY s.contact_id
          ORDER BY xc.companyid DESC NULLS LAST
        ) AS rn
      FROM students s
      LEFT JOIN `analytics-prod.tutoring_ops.company` xc
        ON LOWER(TRIM(s.email)) = LOWER(TRIM(xc.email))
    )
    WHERE rn = 1
  ),

  student_sales AS (
    SELECT
      sc.contact_id,
      DATE(sls.`date`) AS sale_date,
      sls.amount_gross
    FROM student_company sc
    LEFT JOIN `analytics-prod.tutoring_ops.acc_sale` sls
      ON sls.dependency_debtor = 'companyid'
     AND sls.dependency_debtor_id = sc.companyid
    WHERE sls.`date` IS NOT NULL
  ),

  -- First and last invoice bound the student's active window
  invoice_bounds AS (
    SELECT
      contact_id,
      MIN(sale_date) AS first_invoice_date,
      MAX(sale_date) AS last_invoice_date
    FROM student_sales
    GROUP BY contact_id
  ),

  -- Lifetime value: total across all invoices, constant per student
  student_cltv AS (
    SELECT contact_id, SUM(amount_gross) AS cltv_total
    FROM student_sales
    GROUP BY contact_id
  ),

  sales_monthly AS (
    SELECT
      contact_id,
      DATE_TRUNC(sale_date, MONTH) AS sale_month,
      SUM(amount_gross) AS cltv_amount_gross
    FROM student_sales
    GROUP BY contact_id, DATE_TRUNC(sale_date, MONTH)
  ),

  -- Every student × every month
  expanded AS (
    SELECT
      cal.date_date,
      s.contact_id,
      COALESCE(NULLIF(TRIM(s.location_name), ''), 'Unknown') AS location_name
    FROM calendar cal
    CROSS JOIN students s
  )

SELECT
  e.date_date,
  EXTRACT(YEAR    FROM e.date_date) AS date_year,
  EXTRACT(QUARTER FROM e.date_date) AS date_quarter,
  EXTRACT(MONTH   FROM e.date_date) AS date_month,
  EXTRACT(ISOWEEK FROM e.date_date) AS date_week,
  EXTRACT(DAY     FROM e.date_date) AS date_day,

  e.contact_id,
  e.location_name,

  ROUND(sc_cltv.cltv_total, 2)                AS student_cltv,
  ROUND(COALESCE(sm.cltv_amount_gross, 0), 2) AS monthly_revenue,

  -- Historic months evaluate at their own end; current month at today
  LEAST(
    DATE_SUB(DATE_ADD(e.date_date, INTERVAL 1 MONTH), INTERVAL 1 DAY),
    CURRENT_DATE()
  ) AS reference_date,

  -- 42-day activity rule
  CASE
    WHEN ib.first_invoice_date IS NULL THEN FALSE
    WHEN ib.first_invoice_date <=
           LEAST(DATE_SUB(DATE_ADD(e.date_date, INTERVAL 1 MONTH), INTERVAL 1 DAY), CURRENT_DATE())
     AND ib.last_invoice_date >=
           DATE_SUB(LEAST(DATE_SUB(DATE_ADD(e.date_date, INTERVAL 1 MONTH), INTERVAL 1 DAY), CURRENT_DATE()), INTERVAL 42 DAY)
      THEN TRUE
    ELSE FALSE
  END AS is_active_student,

  -- Helper: contact_id when active, NULL otherwise — lets a BI tool
  -- do COUNT(DISTINCT) for active students without a filter
  CASE
    WHEN ib.first_invoice_date IS NULL THEN NULL
    WHEN ib.first_invoice_date <=
           LEAST(DATE_SUB(DATE_ADD(e.date_date, INTERVAL 1 MONTH), INTERVAL 1 DAY), CURRENT_DATE())
     AND ib.last_invoice_date >=
           DATE_SUB(LEAST(DATE_SUB(DATE_ADD(e.date_date, INTERVAL 1 MONTH), INTERVAL 1 DAY), CURRENT_DATE()), INTERVAL 42 DAY)
      THEN e.contact_id
    ELSE NULL
  END AS contact_id_active

FROM expanded e
LEFT JOIN invoice_bounds ib ON ib.contact_id = e.contact_id
LEFT JOIN student_cltv sc_cltv ON sc_cltv.contact_id = e.contact_id
LEFT JOIN sales_monthly sm
  ON sm.contact_id = e.contact_id
 AND sm.sale_month = e.date_date
