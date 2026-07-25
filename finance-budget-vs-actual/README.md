# Budget vs. Actual — Financial Reporting Pipeline

**Problem:** A creative agency's finance data couldn't be compared
against budget. Accounting periods were buried inside text
identifiers rather than stored as dates, budgets lived as single
date-range records while actuals were monthly transactions, and two
business units ran through a single ledger with no way to split them.
Answering "are we on budget this month?" meant rebuilding
spreadsheets by hand.

**Approach:** Built a three-layer BigQuery pipeline:

| Layer | File | What it does |
|---|---|---|
| Actuals | `01_actuals.sql` | Parses periods out of raw text identifiers, whitelists reportable GL accounts, maps revenue/cost categories and business units |
| Forecasts | `02_forecasts.sql` | Expands each budget's date range into monthly rows with `GENERATE_DATE_ARRAY`, shaped into the identical schema as actuals |
| Variance | `03_variance.sql` | Full outer join across account and month, producing variance, variance % and achievement % with zero-division guards |

The design principle: make forecast and actual **structurally
identical** so they can be joined directly, rather than reconciled
by hand each month.

**Tools:** Google BigQuery, Standard SQL

**Outcome:** Budget-vs-actual reporting available per GL account,
per month and per business unit from a single query layer — with
no manual spreadsheet consolidation in the flow.

---

*Table and dataset names have been genericised. Client identifying
details removed.*
