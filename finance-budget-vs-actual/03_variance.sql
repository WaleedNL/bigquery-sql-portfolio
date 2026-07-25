/* ============================================================
   Finance Pipeline — Layer 3: Variance
   ------------------------------------------------------------
   Author:  Waleed Jawaid | Data Specialist
   Tool:    Google BigQuery (Standard SQL)

   Purpose:
     Compares the actuals and forecast layers to answer the
     core question: are we tracking to budget?

   Logic:
     - Aggregates each side to month / GL account level
     - FULL OUTER JOIN so accounts that exist in only one side
       (unbudgeted spend, or budget with no activity yet) are
       still returned rather than silently dropped
     - Variance   = forecast - actual
     - Achievement = actual / forecast
     - Every ratio is guarded against division by zero
     - has_actuals / has_forecast flags let a dashboard show
       what's genuinely missing vs. genuinely zero

   Output:
     One row per month / GL account with forecast, actual,
     variance and achievement metrics.
   ============================================================ */

WITH actuals_by_gl AS (
  SELECT
    date_date, date_year, date_month,
    gl_code, gl_description, gl_type, gl_type_label,
    SUM(revenue_amount) AS actual_revenue,
    SUM(cost_amount)    AS actual_costs,
    SUM(profit_amount)  AS actual_profit,
    organization_group
  FROM `agency_finance.finance_actuals`
  GROUP BY date_date, date_year, date_month, gl_code, gl_description,
           gl_type, gl_type_label, organization_group
),

forecasts_by_gl AS (
  SELECT
    date_date, date_year, date_month,
    gl_code, gl_description, gl_type, gl_type_label,
    SUM(revenue_amount) AS forecast_revenue,
    SUM(cost_amount)    AS forecast_costs,
    SUM(profit_amount)  AS forecast_profit,
    organization_group
  FROM `agency_finance.finance_forecasts`
  GROUP BY date_date, date_year, date_month, gl_code, gl_description,
           gl_type, gl_type_label, organization_group
)

SELECT
  -- ---------- GL account identity ----------
  COALESCE(a.gl_code,        f.gl_code)        AS gl_code,
  COALESCE(a.gl_description, f.gl_description) AS gl_description,
  COALESCE(a.gl_type,        f.gl_type)        AS gl_type,
  COALESCE(a.gl_type_label,  f.gl_type_label)  AS gl_type_label,

  -- ---------- Forecast ----------
  ROUND(COALESCE(f.forecast_revenue, 0), 2) AS forecast_revenue,
  ROUND(COALESCE(f.forecast_costs,   0), 2) AS forecast_costs,
  ROUND(COALESCE(f.forecast_profit,  0), 2) AS forecast_profit,

  -- ---------- Actual ----------
  ROUND(COALESCE(a.actual_revenue, 0), 2) AS actual_revenue,
  ROUND(COALESCE(a.actual_costs,   0), 2) AS actual_costs,
  ROUND(COALESCE(a.actual_profit,  0), 2) AS actual_profit,

  -- ---------- Variance (forecast - actual) ----------
  ROUND(COALESCE(f.forecast_revenue, 0) - COALESCE(a.actual_revenue, 0), 2) AS variance_revenue,
  ROUND(COALESCE(f.forecast_costs,   0) - COALESCE(a.actual_costs,   0), 2) AS variance_costs,
  ROUND(COALESCE(f.forecast_profit,  0) - COALESCE(a.actual_profit,  0), 2) AS variance_profit,

  -- ---------- Variance %  (NULL rather than error when no budget) ----------
  ROUND(CASE WHEN COALESCE(f.forecast_revenue, 0) != 0
    THEN ((COALESCE(f.forecast_revenue, 0) - COALESCE(a.actual_revenue, 0))
          / COALESCE(f.forecast_revenue, 0)) * 100 END, 2) AS variance_revenue_pct,

  ROUND(CASE WHEN COALESCE(f.forecast_costs, 0) != 0
    THEN ((COALESCE(f.forecast_costs, 0) - COALESCE(a.actual_costs, 0))
          / COALESCE(f.forecast_costs, 0)) * 100 END, 2) AS variance_costs_pct,

  ROUND(CASE WHEN COALESCE(f.forecast_profit, 0) != 0
    THEN ((COALESCE(f.forecast_profit, 0) - COALESCE(a.actual_profit, 0))
          / COALESCE(f.forecast_profit, 0)) * 100 END, 2) AS variance_profit_pct,

  -- ---------- Achievement % (actual as share of budget) ----------
  ROUND(CASE WHEN COALESCE(f.forecast_revenue, 0) != 0
    THEN (COALESCE(a.actual_revenue, 0) / COALESCE(f.forecast_revenue, 0)) * 100 END, 2)
    AS achievement_revenue_pct,

  ROUND(CASE WHEN COALESCE(f.forecast_costs, 0) != 0
    THEN (COALESCE(a.actual_costs, 0) / COALESCE(f.forecast_costs, 0)) * 100 END, 2)
    AS achievement_costs_pct,

  ROUND(CASE WHEN COALESCE(f.forecast_profit, 0) != 0
    THEN (COALESCE(a.actual_profit, 0) / COALESCE(f.forecast_profit, 0)) * 100 END, 2)
    AS achievement_profit_pct,

  -- ---------- Data availability flags ----------
  (a.actual_revenue IS NOT NULL OR a.actual_costs IS NOT NULL)     AS has_actuals,
  (f.forecast_revenue IS NOT NULL OR f.forecast_costs IS NOT NULL) AS has_forecast,

  -- ---------- Date dimensions ----------
  COALESCE(a.date_date,  f.date_date)  AS date_date,
  COALESCE(a.date_year,  f.date_year)  AS date_year,
  COALESCE(a.date_month, f.date_month) AS date_month,
  EXTRACT(QUARTER FROM COALESCE(a.date_date, f.date_date)) AS date_quarter,
  EXTRACT(ISOWEEK FROM COALESCE(a.date_date, f.date_date)) AS date_week,
  1 AS date_day,

  a.organization_group

FROM actuals_by_gl a
FULL OUTER JOIN forecasts_by_gl f
  ON  a.date_year  = f.date_year
  AND a.date_month = f.date_month
  AND a.gl_code    = f.gl_code

ORDER BY date_year DESC, date_month DESC, gl_type_label, gl_code
