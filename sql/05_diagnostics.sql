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

-- 7. Cross-check: normal approximation vs Poisson model of lead-time demand
WITH flagged AS (
  SELECT 
    r.product_id, r.description, r.risk_status,
    r.on_hand_units AS s,                                  -- inventory position (on-order = 0)
    r.projected_daily_demand * r.lead_time_days AS lam,    -- mean demand over the lead time
    p.unit_margin,
    r.stockout_probability AS normal_prob,
    r.margin_at_risk AS normal_margin
  FROM `inventory_risk_us.fct_risk_scoring` r
  JOIN `inventory_risk_us.dim_product` p USING (product_id)
  WHERE r.risk_status IN ('CRITICAL_STOCKOUT', 'REORDER_NOW')   -- remove this line to run every product with demand
    AND r.projected_daily_demand > 0
),
pmf AS (
  SELECT 
    f.product_id, f.s, k,
    EXP(-f.lam + k * LN(f.lam)
        - SUM(IFNULL(SAFE.LN(k), 0)) OVER (PARTITION BY f.product_id ORDER BY k)) AS p
  FROM flagged f, UNNEST(GENERATE_ARRAY(0, f.s)) AS k
),
agg AS (
  SELECT 
    product_id,
    GREATEST(1 - SUM(p), 0) AS p_gt_s,                     -- P(D > S)
    GREATEST(1 - SUM(IF(k < s, p, 0)), 0) AS p_ge_s        -- P(D >= S)
  FROM pmf
  GROUP BY product_id
)
SELECT 
  f.product_id, f.description, f.risk_status, f.s AS on_hand_units,
  ROUND(f.lam, 3) AS mean_lead_time_demand,
  f.normal_prob,
  ROUND(a.p_gt_s, 4) AS poisson_prob,
  f.normal_margin,
  ROUND(GREATEST(f.lam * a.p_ge_s - f.s * a.p_gt_s, 0) * f.unit_margin, 2) AS poisson_margin
FROM flagged f
JOIN agg a USING (product_id)
ORDER BY poisson_margin DESC;