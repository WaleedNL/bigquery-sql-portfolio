/* ============================================================
   Tutoring Retention Analytics — Layer 2
   Student Activation Cohorts
   ------------------------------------------------------------
   Author:  Waleed Jawaid | Data Specialist
   Tool:    Google BigQuery (Standard SQL)

   Purpose:
     Identifies the moment each student became a paying customer
     and groups them into activation cohorts.

   Definition:
     Activation date = first invoice date, reached via the
     contact → company → invoice bridge. One row per student who
     has at least one invoice.

   Why it exists:
     "How many new students did we activate this year, per
     location?" could not be answered from either source system.
     The CRM knows contacts but not payment; accounting knows
     payment but not location or marketing origin.

   Notes:
     - The time axis here is the activation date, not the
       invoice date — so date filters slice cohorts, not revenue.
     - student_cltv is full lifetime revenue and is deliberately
       NOT limited by the selected period. Combined with cohort
       year it answers: "what is a student activated in 2023
       worth over their whole life?"
     - calendar_year is exposed as an explicit alias to make a
       later migration to academic-year reporting straightforward.

   Output:
     One row per activated student with cohort date dimensions,
     location, lifetime value and a current-activity flag.
   ============================================================ */

WITH
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

  -- INNER JOIN: only students who actually have invoices
  student_sales AS (
    SELECT
      sc.contact_id,
      sc.location_name,
      DATE(sls.`date`) AS sale_date,
      sls.amount_gross
    FROM student_company sc
    INNER JOIN `analytics-prod.tutoring_ops.acc_sale` sls
      ON sls.dependency_debtor = 'companyid'
     AND sls.dependency_debtor_id = sc.companyid
    WHERE sls.`date` IS NOT NULL
  ),

  invoice_bounds AS (
    SELECT
      contact_id,
      ANY_VALUE(location_name) AS location_name,
      MIN(sale_date) AS first_invoice_date,
      MAX(sale_date) AS last_invoice_date,
      SUM(amount_gross) AS student_cltv
    FROM student_sales
    GROUP BY contact_id
  )

SELECT
  -- Time axis is the activation date
  ib.first_invoice_date                       AS date_date,
  EXTRACT(YEAR    FROM ib.first_invoice_date) AS date_year,
  EXTRACT(QUARTER FROM ib.first_invoice_date) AS date_quarter,
  EXTRACT(MONTH   FROM ib.first_invoice_date) AS date_month,
  EXTRACT(ISOWEEK FROM ib.first_invoice_date) AS date_week,
  EXTRACT(DAY     FROM ib.first_invoice_date) AS date_day,
  EXTRACT(YEAR    FROM ib.first_invoice_date) AS calendar_year,

  ib.contact_id,
  COALESCE(NULLIF(TRIM(ib.location_name), ''), 'Unknown') AS location_name,

  ib.first_invoice_date,
  ib.last_invoice_date,
  ROUND(ib.student_cltv, 2) AS student_cltv,

  -- Is this student still active as of today?
  (ib.last_invoice_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 42 DAY))
    AS is_active_student_now,

  CASE
    WHEN ib.last_invoice_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 42 DAY)
      THEN ib.contact_id
    ELSE NULL
  END AS contact_id_active_now,

  -- Helper for SUM-based counting in BI tools
  1 AS activated_student_cnt

FROM invoice_bounds ib
