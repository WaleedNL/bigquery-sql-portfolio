/* ============================================================
   Newbank — Customer Transaction & Revenue Analysis
   ------------------------------------------------------------
   Author:  Waleed | Data Specialist
   Tool:    Google BigQuery (Standard SQL)

   Purpose:
     Builds a clean, enriched transaction-level dataset for a
     digital neobank. Joins raw transactions to the user table
     and derives a readable transaction category, so downstream
     dashboards can analyze fee revenue and customer behaviour.

   Logic:
     - Pulls completed FEE transactions (fee revenue events)
     - Enriches each transaction with the user's service plan,
       join date, and country
     - Maps NULL merchant categories to clear business labels
       (Exchanges, Fund Transfer, Refunds, Fees, etc.)

   Output:
     One row per fee transaction, enriched with user context —
     ready for revenue and retention analysis in Power BI /
     Looker Studio.
   ============================================================ */

SELECT
    transaction_id
  , user_id
  , transaction_type
  , transaction_currency
  , amount_usd AS revenue
  , transaction_state
  , cardholder_presence
  , merchant_mcc
  , merchant_country
  , direction
  , transaction_date
  -- Give NULL merchant categories a readable business label
  , CASE
      WHEN merchant_category IS NULL AND transaction_type = 'EXCHANGE' THEN 'Exchanges'
      WHEN merchant_category IS NULL AND transaction_type = 'TRANSFER' THEN 'Fund Transfer'
      WHEN merchant_category IS NULL AND transaction_type = 'REFUND'   THEN 'Refunds'
      WHEN merchant_category IS NULL AND transaction_type = 'FEE'      THEN 'Fees'
      WHEN merchant_category IS NULL AND transaction_type = 'TOPUP'    THEN 'Fund Topup'
      WHEN merchant_category IS NULL AND transaction_type = 'CASHBACK' THEN 'Cashback'
      WHEN merchant_category IS NULL AND transaction_type = 'TAX'      THEN 'Taxes'
      ELSE merchant_category
    END AS transaction_category
  , b.service_plan
  , b.created_date AS joined_date
  , b.country      AS user_country
FROM `le-wagon-1708-neobank.neo_bank.transactions__mcc`
LEFT JOIN `le-wagon-1708-neobank.neo_bank.users` AS b
  USING (user_id)
WHERE transaction_type  = 'FEE'
  AND transaction_state = 'COMPLETED'
