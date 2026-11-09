-- Single source of truth for run parameters + assumption seed.
-- Run order: 00 -> 01 -> 02 -> 03 -> 04   (05 = diagnostics)
--
-- NOTE: bigquery-public-data.thelook_ecommerce is refreshed periodically, so results
-- change between runs. as_of_date is taken from the data (not CURRENT_DATE()) for consistency. 

CREATE OR REPLACE TABLE `inventory_risk_us.params` AS
SELECT
  DATE(MAX(created_at)) AS as_of_date,   -- latest order date in the dataset
  180 AS window_days,                    -- demand statistics window (days)
  365 AS overstock_days,                 -- days of cover above this => OVERSTOCK
  -- 180 AS dead_stock_days,                -- days of cover above this (with cash buried) => DEAD_STOCK
  90  AS excess_horizon_days,            -- stock beyond this many days of demand counts as "cash buried"
  45  AS order_cycle_days,               -- review/order cycle used for the order-up-to level
  14  AS reorder_soon_days               -- days until that rop reaches
FROM `bigquery-public-data.thelook_ecommerce.order_items`;

-- ASSUMPTION: the dataset has no supplier / lead-time data.
-- Lead times and their variability are assigned per distribution center (editable).
CREATE OR REPLACE TABLE `inventory_risk_us.seed_dc_lead_time` AS
SELECT * FROM UNNEST(ARRAY<STRUCT<distribution_center_id INT64, lead_time_days INT64, lead_time_std_days INT64>>[
  (1, 14, 3), (2, 14, 3),
  (3, 21, 5), (4, 21, 5),
  (5, 30, 7), (6, 30, 7), (7, 30, 7),
  (8, 45, 10), (9, 45, 10), (10, 45, 10)
]);