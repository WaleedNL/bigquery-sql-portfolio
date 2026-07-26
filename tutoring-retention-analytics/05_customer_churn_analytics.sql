/* ============================================================
   Tutoring Retention Analytics — Layer 5
   Customer-Level Churn, CLV and Location Performance
   ------------------------------------------------------------
   Author:  Waleed Jawaid | Data Specialist
   Tool:    Google BigQuery (Standard SQL)

   Purpose:
     Rolls the data up to the paying customer (household) level,
     producing churn status, lifetime value and location
     benchmarks in a single result set.

   Key techniques:
     - Free-text location values are cleaned and typo-corrected
       before grouping, so "AMSTERDAN" and "ANSTERDAM" don't
       fragment the analysis into phantom locations.
     - Window functions compute location-level and company-wide
       benchmarks on the same rows as the customer detail, so a
       dashboard can show "this customer vs. their location
       average" without a second query.
     - Revenue is bucketed into value segments and tenure into
       lifecycle stages, giving BI tools ready-made filters.

   Note:
     Customer-identifying columns (names, email, street address)
     present in the production version have been removed here.

   Output:
     One row per customer with churn status, revenue metrics,
     lifetime value, tenure segment and location benchmarks.
   ============================================================ */

WITH customer_invoice_data AS (
  SELECT
    c.id    AS customer_id,
    c.cdate AS customer_created_date,

    -- Location cleaning: fix known typos, normalise whitespace/case
    CASE
      WHEN UPPER(TRIM(comp.address_town)) IN ('ANSTERDAM', 'AMSERDAM', 'AMSTERDAN')
        THEN 'AMSTERDAM'
      WHEN TRIM(comp.address_town) IS NULL OR TRIM(comp.address_town) = ''
        THEN 'Unknown'
      ELSE UPPER(TRIM(REGEXP_REPLACE(comp.address_town, r'\s+', ' ')))
    END AS location,
    COALESCE(comp.address_country, 'Netherlands') AS country,

    comp.companyid,
    s.salesid,
    s.amount,
    s.date AS invoice_date,
    s.description
  FROM `analytics-prod.crm.contacts` c
  LEFT JOIN `analytics-prod.tutoring_ops.company` comp
    ON c.email = comp.email
  LEFT JOIN `analytics-prod.tutoring_ops.sale` s
    ON comp.companyid = s.companyid
  WHERE c.email IS NOT NULL AND c.email != ''
),

customer_metrics AS (
  SELECT
    customer_id,
    location,
    country,
    customer_created_date,

    COUNT(DISTINCT salesid)        AS total_invoices,
    COALESCE(SUM(amount), 0)       AS total_revenue,
    COALESCE(AVG(amount), 0)       AS average_invoice_amount,
    MIN(invoice_date)              AS first_invoice_date,
    MAX(invoice_date)              AS last_invoice_date,

    -- 42-day churn rule
    DATE_DIFF(CURRENT_DATE(), DATE(MAX(invoice_date)), DAY) AS days_since_last_payment,
    CASE
      WHEN MAX(invoice_date) IS NULL THEN 'No Payments'
      WHEN DATE_DIFF(CURRENT_DATE(), DATE(MAX(invoice_date)), DAY) <= 42 THEN 'Active'
      ELSE 'Inactive'
    END AS customer_status,

    -- Churn date = last invoice + grace period
    CASE
      WHEN DATE_DIFF(CURRENT_DATE(), DATE(MAX(invoice_date)), DAY) > 42
        THEN DATE_ADD(DATE(MAX(invoice_date)), INTERVAL 42 DAY)
    END AS churn_date,

    CASE WHEN DATE_DIFF(CURRENT_DATE(), DATE(MAX(invoice_date)), DAY) > 42
         THEN 1 ELSE 0 END AS is_churned,
    CASE WHEN DATE_DIFF(CURRENT_DATE(), DATE(MAX(invoice_date)), DAY) <= 42
         THEN 1 ELSE 0 END AS is_active,

    -- Households can have several students; count distinct names
    -- appearing in invoice line descriptions
    COUNT(DISTINCT CASE WHEN description IS NOT NULL
      THEN REGEXP_EXTRACT(description, r'([A-Z][a-z]{2,15})') END) AS estimated_student_count,

    -- Revenue divided across the students in the household
    CASE WHEN COUNT(DISTINCT salesid) > 0 THEN
      COALESCE(SUM(amount), 0) / GREATEST(COUNT(DISTINCT
        CASE WHEN description IS NOT NULL
          THEN REGEXP_EXTRACT(description, r'([A-Z][a-z]{2,15})') END), 1)
      ELSE 0
    END AS clv_per_student,

    -- Days from CRM signup to most recent payment
    CASE WHEN MAX(invoice_date) IS NOT NULL AND customer_created_date IS NOT NULL
      THEN DATE_DIFF(DATE(MAX(invoice_date)), DATE(TIMESTAMP(customer_created_date)), DAY)
    END AS customer_lifetime_days,

    COALESCE(SUM(CASE WHEN DATE(invoice_date) >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
      THEN amount END), 0) AS revenue_last_30_days,
    COALESCE(SUM(CASE WHEN DATE(invoice_date) >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
      THEN amount END), 0) AS revenue_last_90_days,
    COALESCE(SUM(CASE WHEN DATE(invoice_date) >= DATE_SUB(CURRENT_DATE(), INTERVAL 365 DAY)
      THEN amount END), 0) AS revenue_last_365_days

  FROM customer_invoice_data
  GROUP BY customer_id, location, country, customer_created_date
)

SELECT
  pm.customer_id,
  pm.location,
  pm.country,

  pm.customer_status,
  pm.days_since_last_payment,
  pm.churn_date,
  pm.is_churned,
  pm.is_active,

  -- Company-wide rates, repeated on every row for BI KPI cards
  COUNT(DISTINCT CASE WHEN pm.customer_status = 'Inactive' THEN pm.customer_id END) OVER()
    AS total_churned_customers,
  COUNT(DISTINCT CASE WHEN pm.customer_status = 'Active' THEN pm.customer_id END) OVER()
    AS total_active_customers,
  COUNT(DISTINCT pm.customer_id) OVER() AS total_customers,

  ROUND(COUNT(DISTINCT CASE WHEN pm.customer_status = 'Inactive' THEN pm.customer_id END) OVER()
    * 100.0 / NULLIF(COUNT(DISTINCT pm.customer_id) OVER(), 0), 2) AS overall_churn_rate,
  ROUND(COUNT(DISTINCT CASE WHEN pm.customer_status = 'Active' THEN pm.customer_id END) OVER()
    * 100.0 / NULLIF(COUNT(DISTINCT pm.customer_id) OVER(), 0), 2) AS overall_retention_rate,

  -- Per-location benchmarks on the same rows as customer detail
  COUNT(DISTINCT pm.customer_id) OVER(PARTITION BY pm.location) AS location_total_customers,
  COUNT(DISTINCT CASE WHEN pm.customer_status = 'Active' THEN pm.customer_id END)
    OVER(PARTITION BY pm.location) AS location_active_customers,

  SUM(pm.estimated_student_count) OVER(PARTITION BY pm.location) AS location_total_students,

  ROUND(SUM(CASE WHEN pm.customer_status = 'Inactive' THEN pm.estimated_student_count ELSE 0 END)
    OVER(PARTITION BY pm.location) * 100.0
    / NULLIF(SUM(pm.estimated_student_count) OVER(PARTITION BY pm.location), 0), 2)
    AS location_student_churn_rate,

  ROUND(SUM(pm.total_revenue) OVER(PARTITION BY pm.location), 2) AS location_total_revenue,
  ROUND(AVG(pm.total_revenue) OVER(PARTITION BY pm.location), 2) AS location_avg_revenue_per_customer,
  ROUND(SUM(pm.total_revenue) OVER(PARTITION BY pm.location)
    / NULLIF(SUM(pm.estimated_student_count) OVER(PARTITION BY pm.location), 0), 2)
    AS location_revenue_per_student,

  pm.estimated_student_count,
  pm.total_invoices,
  pm.total_revenue,
  pm.average_invoice_amount,
  ROUND(pm.clv_per_student, 2) AS clv_per_student,

  ROUND(pm.revenue_last_30_days, 2)  AS revenue_last_30_days,
  ROUND(pm.revenue_last_90_days, 2)  AS revenue_last_90_days,
  ROUND(pm.revenue_last_365_days, 2) AS revenue_last_365_days,

  pm.customer_lifetime_days,
  pm.first_invoice_date,
  pm.last_invoice_date,

  -- Ready-made dashboard filters
  CASE
    WHEN pm.total_revenue = 0   THEN 'No Revenue'
    WHEN pm.total_revenue < 100 THEN 'Low Value (< €100)'
    WHEN pm.total_revenue < 500 THEN 'Medium Value (€100–€500)'
    ELSE 'High Value (> €500)'
  END AS revenue_segment,

  CASE
    WHEN pm.customer_lifetime_days IS NULL THEN 'No Purchase History'
    WHEN pm.customer_lifetime_days < 30    THEN 'New (< 1 month)'
    WHEN pm.customer_lifetime_days < 90    THEN 'Recent (1–3 months)'
    WHEN pm.customer_lifetime_days < 365   THEN 'Established (3–12 months)'
    ELSE 'Long-term (> 1 year)'
  END AS customer_tenure_segment,

  DATE(pm.last_invoice_date)                 AS date_date,
  EXTRACT(YEAR    FROM pm.last_invoice_date) AS date_year,
  EXTRACT(QUARTER FROM pm.last_invoice_date) AS date_quarter,
  EXTRACT(MONTH   FROM pm.last_invoice_date) AS date_month

FROM customer_metrics pm
ORDER BY pm.customer_status, pm.total_revenue DESC, pm.last_invoice_date DESC NULLS LAST
