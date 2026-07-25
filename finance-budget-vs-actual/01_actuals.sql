/* ============================================================
   Finance Pipeline — Layer 1: Actuals
   ------------------------------------------------------------
   Author:  Waleed Jawaid | Data Specialist
   Tool:    Google BigQuery (Standard SQL)

   Purpose:
     Normalises raw ledger transactions into a monthly,
     GL-account-level actuals table for financial reporting.

   Key challenges solved:
     - Accounting periods were stored inside a text identifier
       ('YEARMONTH_2024-03') rather than as a date column, so
       the period is parsed out and rebuilt as a real DATE.
     - Ledger accounts are whitelisted to the ~45 codes that
       carry reportable revenue (Omzet) and cost (Kosten).
     - GL codes are mapped to their operating business unit so
       performance can be split by unit.

   Output:
     One row per month / GL account / beneficiary, with revenue,
     cost and profit amounts plus a full set of date dimensions.
     Schema is deliberately identical to the forecast layer so
     the two can be compared directly.
   ============================================================ */

SELECT
  -- ---------- Period parsed out of the text identifier ----------
  FORMAT('%d',
    CAST(SPLIT(SPLIT(group_identifier, '_')[SAFE_OFFSET(1)], '-')[SAFE_OFFSET(0)] AS INT64)
  ) AS jaar,

  FORMAT_DATE('%B',
    DATE(
      CAST(SPLIT(SPLIT(group_identifier, '_')[SAFE_OFFSET(1)], '-')[SAFE_OFFSET(0)] AS INT64),
      CAST(SPLIT(SPLIT(group_identifier, '_')[SAFE_OFFSET(1)], '-')[SAFE_OFFSET(1)] AS INT64),
      1)
  ) AS maand,

  FORMAT_DATE('%b',
    DATE(
      CAST(SPLIT(SPLIT(group_identifier, '_')[SAFE_OFFSET(1)], '-')[SAFE_OFFSET(0)] AS INT64),
      CAST(SPLIT(SPLIT(group_identifier, '_')[SAFE_OFFSET(1)], '-')[SAFE_OFFSET(1)] AS INT64),
      1)
  ) AS month_name_short,

  -- ---------- GL account identity ----------
  CAST(schemaid AS STRING) AS gl_code,
  COALESCE(schemaid_description, 'Unknown') AS gl_description,
  CONCAT(CAST(schemaid AS STRING), ' - ', COALESCE(schemaid_description, 'Unknown'))
    AS gl_code_description,
  schemaid_type AS gl_type,

  -- O = Omzet (revenue), K = Kosten (cost)
  CASE
    WHEN schemaid_type = 'O' THEN 'Omzet'
    WHEN schemaid_type = 'K' THEN 'Kosten'
    ELSE CONCAT('Type ', COALESCE(schemaid_type, 'Unknown'))
  END AS gl_type_label,

  CASE WHEN schemaid_type = 'O'
    THEN COALESCE(schemaid_description, 'Revenue') ELSE NULL END AS revenue_category,

  CASE WHEN schemaid_type = 'K'
    THEN COALESCE(schemaid_description, 'Cost') ELSE NULL END AS cost_category,

  CASE
    WHEN schemaid_type = 'K' THEN CONCAT('Kosten - ', COALESCE(schemaid_description, 'Onbekend'))
    WHEN schemaid_type = 'O' THEN CONCAT('Omzet - ', COALESCE(schemaid_description, 'Onbekend'))
    ELSE COALESCE(schemaid_description, 'Onbekend')
  END AS category,

  -- ---------- Business unit split ----------
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

  beneficiary_key,
  CAST(beneficiary_id AS STRING) AS beneficiary_id,
  beneficiary_label,

  -- ---------- Amounts (revenue stored negative in source) ----------
  ROUND(CASE WHEN schemaid_type = 'O' THEN -COALESCE(result, 0) ELSE 0 END, 2) AS revenue_amount,
  ROUND(CASE WHEN schemaid_type = 'K' THEN  COALESCE(result, 0) ELSE 0 END, 2) AS cost_amount,
  ROUND(
      (CASE WHEN schemaid_type = 'O' THEN -COALESCE(result, 0) ELSE 0 END)
    - (CASE WHEN schemaid_type = 'K' THEN  COALESCE(result, 0) ELSE 0 END)
  , 2) AS profit_amount,

  'actual' AS data_type,
  COUNT(*) AS transaction_count,

  -- ---------- Date dimensions ----------
  DATE(
    CAST(SPLIT(SPLIT(group_identifier, '_')[SAFE_OFFSET(1)], '-')[SAFE_OFFSET(0)] AS INT64),
    CAST(SPLIT(SPLIT(group_identifier, '_')[SAFE_OFFSET(1)], '-')[SAFE_OFFSET(1)] AS INT64),
    1) AS date_date,

  CAST(SPLIT(SPLIT(group_identifier, '_')[SAFE_OFFSET(1)], '-')[SAFE_OFFSET(0)] AS INT64) AS date_year,
  CAST(SPLIT(SPLIT(group_identifier, '_')[SAFE_OFFSET(1)], '-')[SAFE_OFFSET(1)] AS INT64) AS date_month,

  EXTRACT(QUARTER FROM DATE(
    CAST(SPLIT(SPLIT(group_identifier, '_')[SAFE_OFFSET(1)], '-')[SAFE_OFFSET(0)] AS INT64),
    CAST(SPLIT(SPLIT(group_identifier, '_')[SAFE_OFFSET(1)], '-')[SAFE_OFFSET(1)] AS INT64),
    1)) AS date_quarter,

  EXTRACT(ISOWEEK FROM DATE(
    CAST(SPLIT(SPLIT(group_identifier, '_')[SAFE_OFFSET(1)], '-')[SAFE_OFFSET(0)] AS INT64),
    CAST(SPLIT(SPLIT(group_identifier, '_')[SAFE_OFFSET(1)], '-')[SAFE_OFFSET(1)] AS INT64),
    1)) AS date_week,

  1 AS date_day

FROM `finance-analytics.agency_finance.transactions`
WHERE
  group_identifier LIKE 'YEARMONTH_%'
  AND schemaid_type IN ('O', 'K')
  AND schemaid != 9900
  AND schemaid IN (
    8000, 8003, 8004, 8005, 8007, 8009, 8011, 8014, 8015, 8018,
    2000, 4000, 4100, 4201, 4206, 4205, 4320, 4330, 4340, 4350,
    4610, 4630, 4690, 4730, 4750, 4760, 4890, 4895, 4900, 4905,
    4910, 4920, 4930, 4940, 4980, 4990, 4991, 5050, 5070, 9100,
    8021, 8022, 8023, 8024, 4996)
  AND CAST(SPLIT(SPLIT(group_identifier, '_')[SAFE_OFFSET(1)], '-')[SAFE_OFFSET(0)] AS INT64) >= 2020
GROUP BY
  jaar, maand, month_name_short, gl_code, gl_description, gl_code_description,
  gl_type, gl_type_label, revenue_category, cost_category, category,
  organization_group, beneficiary_key, beneficiary_id, beneficiary_label,
  data_type, date_date, date_year, date_month, date_quarter, date_week,
  date_day, schemaid_type, result
