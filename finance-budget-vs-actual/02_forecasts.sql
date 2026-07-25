/* ============================================================
   Finance Pipeline — Layer 2: Forecasts
   ------------------------------------------------------------
   Author:  Waleed Jawaid | Data Specialist
   Tool:    Google BigQuery (Standard SQL)

   Purpose:
     Turns budget/prognosis records into monthly forecast rows
     that match the actuals table column-for-column.

   Key challenge solved:
     Budgets are stored as a single record with a start and end
     date. Actuals are monthly. GENERATE_DATE_ARRAY expands each
     budget across its own period so both sides share the same
     grain, which is what makes the variance join possible.

   Output:
     One row per month / GL account / budget line, tagged
     data_type = 'forecast'.
   ============================================================ */

WITH budget_base AS (
  SELECT
    b.budgetid,
    b.description,
    b.companyid,
    -- Period boundaries normalised to whole months
    DATE_TRUNC(CAST(b.client_budget_startdate AS DATE), MONTH) AS period_start_month,
    DATE_TRUNC(CAST(b.client_budget_enddate   AS DATE), MONTH) AS period_end_month
  FROM `finance-analytics.agency_finance.budget` b
  WHERE b.client_budget_type = 'prognosis'
    AND b.budgetid != 2
    AND b.client_budget_startdate IS NOT NULL
    AND b.client_budget_enddate IS NOT NULL
    AND CAST(b.client_budget_startdate AS DATE) <= CAST(b.client_budget_enddate AS DATE)
),

base AS (
  SELECT
    bb.budgetid,
    bb.description,
    bb.companyid,
    bb.period_start_month,
    bb.period_end_month,
    bi.budgetitemid,
    bi.schemaid,
    bi.schemaid_description,
    bi.budgetpostid_label,
    bi.price_type,
    CAST(bi.price_quantity AS INT64)   AS price_quantity,
    CAST(bi.price_amount   AS NUMERIC) AS price_amount,
    CAST(bi.quantity       AS NUMERIC) AS quantity
  FROM budget_base bb
  JOIN `finance-analytics.agency_finance.budget_item` bi
    ON bb.budgetid = bi.budgetid
  WHERE bi.budgetpostid_label IN ('Omzet', 'Kosten')
    AND COALESCE(bi.price_amount, 0) != 0
    AND bi.schemaid != 9900
    -- Same GL whitelist as the actuals layer
    AND bi.schemaid IN (
      8000, 8003, 8004, 8005, 8007, 8009, 8011, 8014, 8015, 8018,
      2000, 4000, 4100, 4201, 4206, 4205, 4320, 4330, 4340, 4350,
      4610, 4630, 4690, 4730, 4750, 4760, 4890, 4895, 4900, 4905,
      4910, 4920, 4930, 4940, 4980, 4990, 4991, 5050, 5070, 9100,
      8021, 8022, 8023, 8024, 4996)
),

period_params AS (
  SELECT
    *,
    period_start_month AS year_start,
    period_end_month   AS year_end
  FROM base
  WHERE price_quantity > 0
),

-- Core step: one budget row becomes one row per month in its period
expanded AS (
  SELECT
    budgetid,
    description,
    companyid,
    budgetitemid,
    schemaid,
    schemaid_description,
    budgetpostid_label,
    ROUND((price_amount * quantity), 2) AS monthly_amount,
    period_date
  FROM period_params,
  UNNEST(GENERATE_DATE_ARRAY(year_start, year_end, INTERVAL 1 MONTH)) AS period_date
)

SELECT
  -- ---------- Date dimensions ----------
  FORMAT_DATE('%Y', period_date) AS jaar,
  FORMAT_DATE('%B', period_date) AS maand,
  FORMAT_DATE('%b', period_date) AS month_name_short,

  -- ---------- GL account identity ----------
  COALESCE(CAST(schemaid AS STRING),
    CASE
      WHEN budgetpostid_label = 'Omzet'  THEN 'FORECAST_REV'
      WHEN budgetpostid_label = 'Kosten' THEN 'FORECAST_COST'
      ELSE 'FORECAST_OTHER'
    END) AS gl_code,

  COALESCE(schemaid_description, budgetpostid_label, 'Unknown') AS gl_description,

  CONCAT(
    COALESCE(CAST(schemaid AS STRING),
      CASE
        WHEN budgetpostid_label = 'Omzet'  THEN 'FORECAST_REV'
        WHEN budgetpostid_label = 'Kosten' THEN 'FORECAST_COST'
        ELSE 'FORECAST_OTHER'
      END),
    ' - ',
    COALESCE(schemaid_description, budgetpostid_label, 'Unknown')
  ) AS gl_code_description,

  CASE WHEN budgetpostid_label = 'Omzet' THEN 'O' ELSE 'K' END AS gl_type,
  CASE WHEN budgetpostid_label = 'Omzet' THEN 'Omzet' ELSE 'Kosten' END AS gl_type_label,

  CASE WHEN budgetpostid_label = 'Omzet'
    THEN COALESCE(schemaid_description, 'Revenue') ELSE NULL END AS revenue_category,

  CASE WHEN budgetpostid_label = 'Kosten'
    THEN COALESCE(schemaid_description, 'Cost') ELSE NULL END AS cost_category,

  CASE
    WHEN budgetpostid_label = 'Kosten' THEN CONCAT('Kosten - ', COALESCE(schemaid_description, 'Forecast'))
    WHEN budgetpostid_label = 'Omzet'  THEN CONCAT('Omzet - ',  COALESCE(schemaid_description, 'Forecast'))
    ELSE COALESCE(schemaid_description, 'Forecast')
  END AS category,

  -- ---------- Business unit split (mirrors actuals) ----------
  CASE
    WHEN schemaid IN (8021, 8022, 8023, 8024, 4996) THEN 'Agency Social'
    WHEN schemaid IN (
      8000, 8003, 8004, 8005, 8007, 8009, 8011, 8014, 8015, 8018,
      2000, 4000, 4100, 4201, 4206, 4205, 4320, 4330, 4340, 4350,
      4610, 4630, 4690, 4730, 4750, 4760, 4890, 4895, 4900, 4905,
      4910, 4920, 4930, 4940, 4980, 4990, 4991, 5050, 5070, 9100)
      THEN 'Agency'
    ELSE 'Other'
  END AS organization_group,

  CAST(budgetid     AS STRING) AS beneficiary_key,
  CAST(budgetitemid AS STRING) AS beneficiary_id,
  budgetpostid_label           AS beneficiary_label,

  -- ---------- Amounts ----------
  ROUND(CASE WHEN budgetpostid_label = 'Omzet'  THEN monthly_amount ELSE 0 END, 2) AS revenue_amount,
  ROUND(CASE WHEN budgetpostid_label = 'Kosten' THEN monthly_amount ELSE 0 END, 2) AS cost_amount,
  ROUND(
    CASE
      WHEN budgetpostid_label = 'Omzet'  THEN  monthly_amount
      WHEN budgetpostid_label = 'Kosten' THEN -monthly_amount
      ELSE 0
    END, 2) AS profit_amount,

  'forecast' AS data_type,
  0 AS transaction_count,

  -- ---------- Date dimensions ----------
  period_date                       AS date_date,
  EXTRACT(YEAR    FROM period_date) AS date_year,
  EXTRACT(MONTH   FROM period_date) AS date_month,
  EXTRACT(QUARTER FROM period_date) AS date_quarter,
  EXTRACT(ISOWEEK FROM period_date) AS date_week,
  1 AS date_day

FROM expanded
ORDER BY
  date_year DESC,
  date_month DESC,
  organization_group,
  revenue_amount DESC,
  cost_amount DESC
