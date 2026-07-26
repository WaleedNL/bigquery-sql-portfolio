/* ============================================================
   Tutoring Retention Analytics — Layer 3
   Active Students Over Time, by Location
   ------------------------------------------------------------
   Author:  Waleed Jawaid | Data Specialist
   Tool:    Google BigQuery (Standard SQL)

   Purpose:
     Answers "how many students were active on any given day, at
     any given location?" — retroactively, for the full history.

   Why this is the hard one:
     The source systems only hold a current state. A snapshot
     query can tell you who is active today, but not who was
     active in March 2023. This builds a daily date spine from
     the first invoice in the business to the last invoice plus
     the 42-day grace period, cross-joins it against every
     location, and evaluates each student's active window against
     every day.

     The result is a true time series: active and inactive
     student counts per location per day, which makes trend and
     seasonality analysis possible for the first time.

   Output:
     One row per day per location, with total, active and
     inactive student counts.
   ============================================================ */

WITH
  -- Each student's active window: first invoice to last invoice
  student_activity AS (
    SELECT
      coms.companyid AS studentid,
      MIN(DATE(sls.date)) AS first_invoice_date,
      MAX(DATE(sls.date)) AS last_invoice_date
    FROM `analytics-prod.tutoring_ops.acc_sale` sls
    LEFT JOIN `analytics-prod.tutoring_ops.company` coms
      ON sls.dependency_debtor = 'companyid'
     AND sls.dependency_debtor_id = coms.companyid
    WHERE coms.companyid IS NOT NULL
      AND sls.date IS NOT NULL
    GROUP BY coms.companyid
  ),

  -- Location comes from the CRM, bridged on email
  student_location AS (
    SELECT
      comp.companyid AS studentid,
      ANY_VALUE(
        CASE
          WHEN cfv.value IS NULL OR TRIM(cfv.value) = '' THEN 'Unknown'
          ELSE INITCAP(TRIM(cfv.value))
        END
      ) AS location
    FROM `analytics-prod.crm.contact` c
    LEFT JOIN `analytics-prod.crm.contact_custom_field_value` cfv
      ON c.id = CAST(cfv.contact AS INT64)
     AND cfv.custom_field_id = '7'
    LEFT JOIN `analytics-prod.tutoring_ops.company` comp
      ON LOWER(TRIM(c.email)) = LOWER(TRIM(comp.email))
    WHERE comp.companyid IS NOT NULL
    GROUP BY comp.companyid
  ),

  student_dim AS (
    SELECT
      sa.studentid,
      COALESCE(sl.location, 'Unknown') AS location,
      sa.first_invoice_date,
      sa.last_invoice_date
    FROM student_activity sa
    LEFT JOIN student_location sl ON sl.studentid = sa.studentid
  ),

  location_totals AS (
    SELECT location, COUNT(DISTINCT studentid) AS total_students
    FROM student_dim
    GROUP BY location
  ),

  -- Spine runs to the last invoice + 42 days so the final
  -- students' grace period is fully represented
  bounds AS (
    SELECT
      MIN(first_invoice_date) AS min_date,
      DATE_ADD(MAX(last_invoice_date), INTERVAL 42 DAY) AS max_date_including_grace
    FROM student_dim
  ),

  date_dim AS (
    SELECT
      d AS date_date,
      EXTRACT(YEAR    FROM d) AS date_year,
      EXTRACT(QUARTER FROM d) AS date_quarter,
      EXTRACT(MONTH   FROM d) AS date_month,
      EXTRACT(ISOWEEK FROM d) AS date_week,
      EXTRACT(DAY     FROM d) AS date_day
    FROM bounds, UNNEST(GENERATE_DATE_ARRAY(min_date, max_date_including_grace)) AS d
  ),

  -- Every day × every location, so locations with zero activity
  -- still return rows rather than disappearing from the chart
  date_location_spine AS (
    SELECT
      dd.*,
      lt.location,
      lt.total_students
    FROM date_dim dd
    CROSS JOIN location_totals lt
  ),

  -- The core evaluation: a student counts as active on a given
  -- day if that day falls inside their window + grace period
  active_by_day_location AS (
    SELECT
      dd.date_date,
      sd.location,
      COUNT(DISTINCT sd.studentid) AS active_students
    FROM date_dim dd
    JOIN student_dim sd
      ON sd.first_invoice_date <= dd.date_date
     AND DATE_ADD(sd.last_invoice_date, INTERVAL 42 DAY) >= dd.date_date
    GROUP BY dd.date_date, sd.location
  ),

  overall_totals AS (
    SELECT COUNT(DISTINCT studentid) AS overall_total_students
    FROM student_dim
  )

SELECT
  spine.date_date,
  spine.date_year,
  spine.date_quarter,
  spine.date_month,
  spine.date_week,
  spine.date_day,
  spine.location,
  spine.total_students,

  -- Respects dashboard location filters
  SUM(spine.total_students) OVER (PARTITION BY spine.date_date) AS total_students_filtered,

  IFNULL(act.active_students, 0) AS active_students,
  spine.total_students - IFNULL(act.active_students, 0) AS inactive_students,
  ot.overall_total_students

FROM date_location_spine spine
CROSS JOIN overall_totals ot
LEFT JOIN active_by_day_location act
  ON act.date_date = spine.date_date
 AND act.location  = spine.location
