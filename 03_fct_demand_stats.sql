-- Demand statistics over the window in params, category-level seasonality (de-trended),
-- proper de-seasonalisation, and ABC-XYZ segmentation.
--
-- Seasonality is estimated per CATEGORY, not per product: product-level demand is far too sparse
-- (most products sell < 1 unit/day) and the shop grows over time, so each month's rate is 
-- first normalised by its own calendar year's average (complete years only).
-- Index is clamped to [0.5, 2.0] for stability; missing => 1.0.

CREATE OR REPLACE TABLE `inventory_risk_us.fct_demand_stats` AS
WITH prm AS (SELECT * FROM `inventory_risk_us.params`)

-- 1. Calculate monthly sales velocity by category
, cat_month AS (
  SELECT 
    category, m, 
    SAFE_DIVIDE(units, EXTRACT(DAY FROM LAST_DAY(m))) AS daily_rate -- daily sales velocity
  FROM (
    SELECT
      p.category,
      DATE_TRUNC(DATE(oi.created_at), MONTH) AS m,
      COUNTIF(oi.status != 'Cancelled') AS units
    FROM `bigquery-public-data.thelook_ecommerce.order_items` oi
    JOIN `bigquery-public-data.thelook_ecommerce.products` p ON p.id = oi.product_id
    GROUP BY 1, 2
  ), prm
  WHERE m > (SELECT DATE_TRUNC(DATE(MIN(created_at)), MONTH) FROM `bigquery-public-data.thelook_ecommerce.order_items`)
    AND m < DATE_TRUNC(prm.as_of_date, MONTH)                           -- drop partial first and current month
)

-- 2. Standardize sales velocity on an annual basis (excluding organic growth)
, cat_ratio AS (
  SELECT
    category,
    EXTRACT(MONTH FROM m) AS month_no,
    daily_rate,
    COUNT(*) OVER (PARTITION BY category, EXTRACT(YEAR FROM m)) AS months_in_year,
    AVG(daily_rate) OVER (PARTITION BY category, EXTRACT(YEAR FROM m)) AS year_avg_rate
  FROM cat_month
)

-- 3. Calculate seasonal_index with amplitude clamping
, seasonality AS (
  SELECT
    category, month_no,
    LEAST(GREATEST(SAFE_DIVIDE(SUM(daily_rate), SUM(year_avg_rate)), 0.5), 2.0) AS seasonal_index 
    -- clamp in the range 0.5-2 to avoid abnormal fluctuation as short-term flash sales
  FROM cat_ratio
  WHERE months_in_year = 12                                             -- take completed calendar years only
  GROUP BY category, month_no
)

-- 4. Pull in seasonal_index for the coming month
, next_month AS (
  SELECT s.category, s.seasonal_index AS next_month_index
  FROM seasonality s
  CROSS JOIN prm
  WHERE s.month_no = EXTRACT(MONTH FROM DATE_ADD(prm.as_of_date, INTERVAL 1 MONTH))
)

-- 5. Raw demand statistics within a window days
, window_stats AS (
  SELECT
    d.product_id,
    COUNT(*) AS observed_days,
    SUM(d.demand_units) AS units_window,                                -- total units sold during window_days defined in params
    COUNTIF(d.demand_units > 0) AS days_with_sale,                      -- to identify intermittent units sold
    AVG(d.demand_units) AS avg_daily_demand_raw,                        -- raw average daily sales rate
    STDDEV_SAMP(d.demand_units) AS std_daily_demand_raw,                -- raw volatility
    AVG(COALESCE(se.seasonal_index, 1.0)) AS window_seasonal_index      -- average seasonal_index during window
  FROM `inventory_risk_us.fct_daily_demand` d
  JOIN `inventory_risk_us.dim_product` p USING (product_id)
  LEFT JOIN seasonality se ON se.category = p.category AND se.month_no = d.month_no
  CROSS JOIN prm
  WHERE d.day > DATE_SUB(prm.as_of_date, INTERVAL prm.window_days DAY)
  GROUP BY d.product_id
)

-- 6. De-seasonalize to base demand: base demand = avg demand raw / window_seasonal_index
, scored AS (
  SELECT
    w.*,
    p.category,
    w.units_window * p.unit_price AS revenue_window,
    COALESCE(n.next_month_index, 1.0) AS next_month_seasonal_index,
    SAFE_DIVIDE(w.avg_daily_demand_raw, w.window_seasonal_index) AS base_daily_demand,
    SAFE_DIVIDE(COALESCE(w.std_daily_demand_raw, 0), w.window_seasonal_index) AS base_std_daily_demand
  FROM window_stats w
  JOIN `inventory_risk_us.dim_product` p USING (product_id)
  LEFT JOIN next_month n ON n.category = p.category
)

-- 7. Forecasting & Revenue Accumulation for ABCXYZ segmentation 
, ranked AS (
  SELECT
    *,
    base_daily_demand * next_month_seasonal_index AS projected_daily_demand,
    base_std_daily_demand * next_month_seasonal_index AS projected_std_daily_demand,
    SUM(revenue_window) OVER () AS total_revenue,
    SUM(revenue_window) OVER (ORDER BY revenue_window DESC, product_id
                              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_revenue
  FROM scored
)

-- 8. Classification & Labeling
SELECT
  product_id,
  category,
  observed_days,
  units_window,
  days_with_sale,
  CASE
    WHEN units_window = 0 THEN 'NO_DEMAND'
    WHEN SAFE_DIVIDE(days_with_sale, observed_days) < 0.2 THEN 'INTERMITTENT' -- sold on fewer than 20% of the days
    ELSE 'REGULAR'
  END AS demand_pattern,
  ROUND(avg_daily_demand_raw, 6) AS avg_daily_demand,
  ROUND(COALESCE(std_daily_demand_raw, 0), 6) AS std_daily_demand,
  ROUND(window_seasonal_index, 3) AS window_seasonal_index,
  ROUND(next_month_seasonal_index, 3) AS next_month_seasonal_index,
  ROUND(base_daily_demand, 6) AS base_daily_demand,
  ROUND(projected_daily_demand, 6) AS projected_daily_demand,
  ROUND(projected_std_daily_demand, 6) AS projected_std_daily_demand,
  ROUND(revenue_window, 2) AS revenue_window,
  CASE
    WHEN revenue_window = 0 THEN 'C'
    WHEN running_revenue / total_revenue <= 0.80 THEN 'A'
    WHEN running_revenue / total_revenue <= 0.95 THEN 'B'
    ELSE 'C'
  END AS abc_class,                                                     -- 80/20 Pareto value segmentation
  CASE
    WHEN units_window = 0 THEN 'Z'
    WHEN SAFE_DIVIDE(std_daily_demand_raw, avg_daily_demand_raw) <= 0.5 THEN 'X'
    WHEN SAFE_DIVIDE(std_daily_demand_raw, avg_daily_demand_raw) <= 1.0 THEN 'Y'
    ELSE 'Z'                                                            -- Demand volatility segmentation based on Coefficient of Variation (CV = σ/μ) 
  END AS xyz_class                                                      -- to normalize risk level against sales volume
FROM ranked; 
