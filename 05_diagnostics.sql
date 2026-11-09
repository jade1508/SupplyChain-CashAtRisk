-- Run each query separately AFTER 00-04. Send the results back to review whether the
-- output is informative or collapsed into one status.

-- 0. Which date is the data "as of", and how many products are in scope?
SELECT as_of_date, window_days FROM `inventory_risk_us.params`;
SELECT COUNT(*) AS products FROM `inventory_risk_us.dim_product`;

-- 1. Reconciliation: does "sold" in inventory_items match order_items?
SELECT
  (SELECT COUNTIF(sold_at IS NOT NULL) FROM `bigquery-public-data.thelook_ecommerce.inventory_items`) AS inv_items_sold,
  (SELECT COUNTIF(status != 'Cancelled') FROM `bigquery-public-data.thelook_ecommerce.order_items`) AS order_items_not_cancelled,
  (SELECT COUNT(*) FROM `bigquery-public-data.thelook_ecommerce.order_items`) AS order_items_all,
  (SELECT SUM(units_sold_lifetime) FROM `inventory_risk_us.dim_product`) AS dim_product_units_sold;

-- 2. Status distribution: should NOT be dominated by a single status
SELECT risk_status, COUNT(*) AS products,
       ROUND(SUM(total_cash_at_risk), 0) AS cash_at_risk,
       ROUND(SUM(inventory_value), 0) AS inventory_value
FROM `inventory_risk_us.fct_risk_scoring`
GROUP BY risk_status
ORDER BY MIN(severity_rank);

-- 3. Days-of-cover distribution (deciles)
SELECT APPROX_QUANTILES(days_of_cover, 10) AS days_of_cover_deciles
FROM `inventory_risk_us.fct_risk_scoring`;

-- 4. Demand pattern mix and status by pattern
SELECT demand_pattern, risk_status, COUNT(*) AS products
FROM `inventory_risk_us.fct_risk_scoring`
GROUP BY 1, 2
ORDER BY 1, 2;

-- 5. Non-trivial outputs (these were constant in the previous version)
SELECT COUNTIF(suggested_order_qty > 0) AS products_needing_order,
       COUNT(DISTINCT order_deadline_date) AS distinct_deadlines,
       APPROX_QUANTILES(stockout_probability, 10) AS stockout_prob_deciles
FROM `inventory_risk_us.fct_risk_scoring`;

-- 6. ABC x XYZ coverage
SELECT abc_class, xyz_class, COUNT(*) AS products
FROM `inventory_risk_us.fct_risk_scoring`
GROUP BY 1, 2
ORDER BY 1, 2;