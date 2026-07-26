# Student Retention & Revenue Analytics

**Problem:** A multi-location tutoring business ran marketing in a
CRM and billing in an accounting system, with no link between the
two. They couldn't say how many students were currently active,
how that number had moved over time, which locations were growing
or shrinking, or what a student was worth over their lifetime.
"Active student" wasn't even defined anywhere in the data.

**Approach:** Built a five-layer BigQuery analytics model:

| Layer | File | What it does |
|---|---|---|
| Activity | `01_student_activity_view.sql` | Student × month grain with a 42-day activity rule, lifetime value and monthly revenue |
| Activation | `02_student_activation_view.sql` | Identifies each student's first invoice as their activation date, enabling cohort analysis |
| Time series | `03_active_students_timeseries.sql` | Daily date spine × location — reconstructs active/inactive counts for the full history |
| Revenue | `04_revenue_by_programme.sql` | Recovers programme names from GL descriptions and splits revenue by programme, student and location |
| Churn & CLV | `05_customer_churn_analytics.sql` | Customer-level churn status, lifetime value and location benchmarks via window functions |

**Three problems worth highlighting:**

*No shared key.* The CRM and accounting system have no common
identifier. The two are bridged on a normalised email address,
with `ROW_NUMBER()` deduplicating contacts that match multiple
company records.

*No activity definition.* The source data has no active/inactive
flag. A 42-day rule was defined and applied consistently across
every layer of the model.

*No history.* Source systems hold current state only. Layer 3
builds a daily date spine across the full invoice history and
evaluates each student's window against every day — turning a
snapshot into a genuine time series that supports trend and
seasonality analysis.

**Tools:** Google BigQuery, Standard SQL

**Outcome:** Active student counts, activation cohorts, lifetime
value and churn — by location and over time — from a single
modelled layer feeding the business's operational dashboards.

---

*Table, dataset and column names have been genericised. Customer-
identifying fields present in the production version have been
removed.*
