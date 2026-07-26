/* ============================================================
   Tutoring Retention Analytics — Layer 4
   Revenue by Programme, Student and Location
   ------------------------------------------------------------
   Author:  Waleed Jawaid | Data Specialist
   Tool:    Google BigQuery (Standard SQL)

   Purpose:
     Splits ledger revenue by the programme a student is enrolled
     in, joined back to student, location and activity status.

   Key detail:
     Programme name is not a field anywhere — it is embedded in
     the GL account description, prefixed with "Revenue ". A
     REGEXP_REPLACE strips the prefix to recover a clean
     programme label. Accounting periods are likewise parsed out
     of a text identifier with REGEXP_EXTRACT.

   Output:
     Revenue per transaction, tagged with programme, student,
     location, activity status and full date dimensions.
   ============================================================ */

WITH
  actual_revenue AS (
    SELECT
      -- Revenue is stored negative in the ledger; flip the sign
      ROUND(CASE WHEN schemaid_type = 'O' THEN -COALESCE(result, 0) ELSE 0 END, 2) AS result,
      tran.group_identifier AS transaction_identifier,

      -- Programme name recovered from the GL description
      TRIM(REGEXP_REPLACE(tran.schemaid_description, r'^(?i)revenue\s+', '')) AS programme,

      tran.beneficiary_id AS companyid,
      CAST(REGEXP_EXTRACT(group_identifier, r'YEARMONTH_(\d{4})-\d{2}') AS INT64) AS trans_year,
      CAST(REGEXP_EXTRACT(group_identifier, r'YEARMONTH_\d{4}-(\d{2})') AS INT64) AS trans_month
    FROM `analytics-prod.tutoring_ops.transaction` tran
    WHERE tran.group_identifier LIKE 'YEARMONTH_%'
      -- Revenue GL accounts only
      AND schemaid IN (8000, 8200, 8201, 8300, 8400, 8500, 8600, 8601, 8604, 8608, 8609)
    GROUP BY 1, 2, 3, 4, 5, 6
  ),

  -- Daily activity flag, same 42-day rule as elsewhere
  active_student AS (
    SELECT
      dtes.date AS date_date,
      coms.companyid AS studentid,
      MAX(COALESCE(DATE(sls.`date`), DATE '1970-01-01'))
        >= DATE_SUB(dtes.date, INTERVAL 42 DAY) AS is_active
    FROM `analytics-prod.tutoring_ops.date_table` dtes
    LEFT JOIN `analytics-prod.tutoring_ops.acc_sale` sls
      ON dtes.date = DATE(sls.date)
    LEFT JOIN `analytics-prod.tutoring_ops.company` coms
      ON sls.dependency_debtor = 'companyid'
     AND sls.dependency_debtor_id = coms.companyid
    GROUP BY 1, 2
  )

SELECT DISTINCT
  ar.result                 AS revenue,
  ar.transaction_identifier AS transaction_identifier,
  ar.programme              AS programme,
  com.companyid             AS studentid,
  ast.is_active             AS student_active,

  INITCAP(LOWER(
    CASE WHEN cfv.value <> '' THEN COALESCE(cfv.value, 'Unknown') ELSE 'Unknown' END
  )) AS location,

  dte.date                        AS date_date,
  EXTRACT(YEAR    FROM dte.date)  AS date_year,
  EXTRACT(QUARTER FROM dte.date)  AS date_quarter,
  EXTRACT(MONTH   FROM dte.date)  AS date_month,
  EXTRACT(ISOWEEK FROM dte.date)  AS date_week,
  EXTRACT(DAY     FROM dte.date)  AS date_day

FROM `analytics-prod.tutoring_ops.date_table` dte
LEFT JOIN `analytics-prod.tutoring_ops.acc_sale` sl
  ON dte.date = DATE(sl.date)
LEFT JOIN `analytics-prod.tutoring_ops.company` com
  ON sl.dependency_debtor = 'companyid'
 AND sl.dependency_debtor_id = com.companyid
LEFT JOIN `analytics-prod.crm.contact` con
  ON com.email = con.email
LEFT JOIN `analytics-prod.crm.contact_custom_field_value` cfv
  ON con.id = CAST(cfv.contact AS INT64)
 AND cfv.custom_field_id = '7'
LEFT JOIN actual_revenue ar
  ON EXTRACT(YEAR  FROM dte.date) = ar.trans_year
 AND EXTRACT(MONTH FROM dte.date) = ar.trans_month
 AND com.companyid = ar.companyid
LEFT JOIN active_student ast
  ON dte.date = ast.date_date
 AND com.companyid = ast.studentid

GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12
ORDER BY 1, 2, 3, 4
