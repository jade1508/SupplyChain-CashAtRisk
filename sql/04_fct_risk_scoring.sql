-- Risk scoring on REAL on-hand stock (from inventory_items).
--
-- Safety stock:  SS  = z * sqrt(L * sigma_d^2 + mu_d^2 * sigma_L^2)
-- Reorder point: ROP = mu_d * L + SS
-- Stockout prob: 1 - Phi(z_stat), Phi approximated by a logistic (1 / (1 + exp(-(0.07056 * z^2 + 1.5976 * z)))) 
-- Expected shortage per lead-time cycle = sigma_lead * G(z), G = standard normal loss function
--
-- ASSUMPTIONS / LIMITS
--  * on-order quantity is unknown in the dataset => treated as 0 (inventory position = on hand)
--  * lead times come from seed_dc_lead_time (assumption)
--  * the normal approximation is weak for intermittent demand (see demand_pattern); read
--    stockout probabilities for INTERMITTENT / NO_DEMAND products as indicative only
--  * margin_at_risk is per replenishment cycle; cash_buried is a balance-sheet figure.
--    They are summed in total_cash_at_risk as a simple exposure indicator, not an accounting loss.

CREATE OR REPLACE TABLE `inventory_risk_us.fct_risk_scoring` AS
WITH prm AS (SELECT * FROM `inventory_risk_us.params`)

-- 1. Aggregate data and assign safety factor (z) based on service level
, base AS (
  SELECT
    p.product_id, p.description, p.category, p.brand, p.department,
    p.distribution_center, p.lead_time_days, p.lead_time_std_days,
    p.unit_cost, p.unit_price, p.unit_margin, p.return_rate,
    p.on_hand_units, p.avg_stock_age_days, p.units_age_lt90, p.units_age_90_180, p.units_age_gt180,
    s.demand_pattern, s.abc_class, s.xyz_class,
    s.projected_daily_demand, s.projected_std_daily_demand,
    CASE s.abc_class WHEN 'A' THEN 2.054 WHEN 'B' THEN 1.645 ELSE 1.282 END AS z_service_level,  -- 98% / 95% / 90%
    prm.as_of_date, prm.overstock_days, prm.excess_horizon_days, prm.order_cycle_days
  FROM `inventory_risk_us.dim_product` p
  JOIN `inventory_risk_us.fct_demand_stats` s USING (product_id)
  CROSS JOIN prm
)

-- 2. Calculate standard deviation of demand during lead time
, lead_time_demand AS (
  SELECT *,
    projected_daily_demand * lead_time_days AS mu_lead_demand,
    SQRT(lead_time_days * POW(projected_std_daily_demand, 2)
         + POW(projected_daily_demand, 2) * POW(lead_time_std_days, 2)) AS sigma_lead_demand
    -- incorporating 2 sources of risk: variability in customer demand and in supplier lead time
  FROM base
)

-- 3. Calculating Reorder Point (ROP) & Days of Cover (DOC)
, rop AS (
  SELECT *,
    mu_lead_demand + z_service_level * sigma_lead_demand AS rop_raw,
    LEAST(IF(projected_daily_demand > 0, on_hand_units / projected_daily_demand, 9999), 9999) AS days_of_cover,
    -- a limit of 9999 when there is no demand
    IF(sigma_lead_demand > 0,
       LEAST(GREATEST((on_hand_units - mu_lead_demand) / sigma_lead_demand, -6), 6),  -- z-score has a near-absolute probability within [-6,6]
       NULL) AS z_stat  -- calculate how many standard deviations the current inventory is from the safety threshold
  FROM lead_time_demand
)

-- 4. Calculate the threat of stockouts, profit margin risks, and cash buried in inventory
, risk AS (
  SELECT *,
    CASE WHEN z_stat IS NULL THEN IF(on_hand_units < mu_lead_demand, 1.0, 0.0)  -- NULL z-stat: absolutely fixed demand OR no data
         ELSE 1 - SAFE_DIVIDE(1, 1 + EXP(-(0.07056 * POW(z_stat, 3) + 1.5976 * z_stat))) END AS stockout_probability, -- logistic approximation to the normal CDF
    CASE WHEN z_stat IS NULL THEN 0.0
         ELSE EXP(-POW(z_stat, 2) / 2) / SQRT(2 * ACOS(-1))
              - z_stat * (1 - SAFE_DIVIDE(1, 1 + EXP(-(0.07056 * POW(z_stat, 3) + 1.5976 * z_stat)))) END AS loss_function, -- standard normal loss function
    GREATEST(on_hand_units - projected_daily_demand * excess_horizon_days, 0) * unit_cost AS cash_buried,
    on_hand_units * unit_cost AS inventory_value,
    IF(projected_daily_demand > 0,
       LEAST(GREATEST(ROUND((on_hand_units - rop_raw) / projected_daily_demand), -30), 180),  -- [-30,180] is a normalized value range for cleaner visualization
       180) AS days_until_reorder -- estimated number of days until current inventory reaches ROP
  FROM rop
)

-- 5. Assigning risk_status and severity_rank
SELECT
  CONCAT(product_id, ' | ', description) AS product_label,   -- label for the dashboard dropdown
  product_id, description, category, brand, department, distribution_center, as_of_date,
  abc_class, xyz_class, demand_pattern,
  on_hand_units,
  ROUND(days_of_cover, 1) AS days_of_cover,
  lead_time_days,
  avg_stock_age_days, units_age_lt90, units_age_90_180, units_age_gt180,
  ROUND(projected_daily_demand, 6) AS projected_daily_demand,
  ROUND(z_service_level * sigma_lead_demand, 1) AS safety_stock_units,
  ROUND(rop_raw, 1) AS reorder_point_units,
  SAFE_DIVIDE(on_hand_units - rop_raw, projected_daily_demand) AS days_until_rop,
  CASE
    WHEN projected_daily_demand > 0 AND on_hand_units <= rop_raw
    THEN CAST(CEIL(rop_raw + projected_daily_demand * order_cycle_days - on_hand_units) AS INT64)
    ELSE 0
  END AS suggested_order_qty,
  DATE_ADD(as_of_date, INTERVAL CAST(days_until_reorder AS INT64) DAY) AS order_deadline_date,
  ROUND(stockout_probability, 4) AS stockout_probability,
  ROUND(loss_function * sigma_lead_demand * unit_margin, 2) AS margin_at_risk,
  ROUND(cash_buried, 2) AS cash_buried,
  ROUND(inventory_value, 2) AS inventory_value,
  ROUND(loss_function * sigma_lead_demand * unit_margin + cash_buried, 2) AS total_cash_at_risk,
  CASE
-- risk_status
    WHEN on_hand_units <= rop_raw AND projected_daily_demand > 0 AND abc_class = 'A' THEN 'CRITICAL_STOCKOUT'
    WHEN on_hand_units <= rop_raw AND projected_daily_demand > 0 THEN 'REORDER_NOW'
    WHEN on_hand_units > rop_raw
        AND projected_daily_demand > 0
        AND SAFE_DIVIDE(on_hand_units - rop_raw, projected_daily_demand)
          <= (SELECT reorder_soon_days FROM prm) THEN 'REORDER_SOON'
    WHEN days_of_cover >= 9999 AND cash_buried > 0 THEN 'DEAD_STOCK'          -- no sale in the window
    WHEN on_hand_units > 0 AND days_of_cover > 730 THEN 'SEVERE_OVERSTOCK'    -- more than 2 years of cover
    WHEN on_hand_units > 0 AND days_of_cover > overstock_days THEN 'OVERSTOCK'
    ELSE 'HEALTHY'
  END AS risk_status,
  CASE
    WHEN on_hand_units <= rop_raw AND projected_daily_demand > 0 AND abc_class = 'A' THEN 1
    WHEN on_hand_units <= rop_raw AND projected_daily_demand > 0 THEN 2
    WHEN on_hand_units > rop_raw
        AND projected_daily_demand > 0
        AND SAFE_DIVIDE(on_hand_units - rop_raw, projected_daily_demand)
          <= (SELECT reorder_soon_days FROM prm) THEN 3
    WHEN days_of_cover >= 9999 AND cash_buried > 0 THEN 4
    WHEN on_hand_units > 0 AND days_of_cover > 730 THEN 5
    WHEN on_hand_units > 0 AND days_of_cover > overstock_days THEN 6
    ELSE 9                      -- for easier management of HEALTHY products
  END AS severity_rank
FROM risk;