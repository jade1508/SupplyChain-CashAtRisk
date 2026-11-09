-- Daily demand per product over the last 365 days, with a calendar spine so zero-demand days are kept
-- (otherwise variance is underestimated).
-- Demand definition: units ordered and not cancelled (returns do NOT reduce demand here;
-- returned_units is kept for reference).
-- The spine starts at the product's first stock date, so new products are not penalised
-- with fake zero days before they existed.

CREATE OR REPLACE TABLE `inventory_risk_us.fct_daily_demand` AS
WITH prm AS (SELECT * FROM `inventory_risk_us.params`)

-- 1. Create calendar spine
, calendar AS (
  SELECT day
  FROM prm, UNNEST(GENERATE_DATE_ARRAY(DATE_SUB(prm.as_of_date, INTERVAL 364 DAY), prm.as_of_date)) AS day
)

, spine AS (
  SELECT d.product_id, c.day
  FROM `inventory_risk_us.dim_product` d
  JOIN calendar c
    ON c.day >= COALESCE(d.first_stock_date, d.first_sale_date)
)

, daily AS (
  SELECT
    CAST(product_id AS STRING) AS product_id,
    DATE(created_at) AS day,
    COUNTIF(status != 'Cancelled') AS gross_units,
    COUNTIF(status = 'Returned') AS returned_units
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
  GROUP BY product_id, day
)

-- 2. Generate daily demand data for each product
SELECT
  s.product_id,
  s.day,
  COALESCE(d.gross_units, 0) AS demand_units,
  COALESCE(d.returned_units, 0) AS returned_units,
  EXTRACT(MONTH FROM s.day) AS month_no
FROM spine s
LEFT JOIN daily d USING (product_id, day);