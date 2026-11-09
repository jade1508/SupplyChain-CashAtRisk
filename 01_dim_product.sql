-- Product dimension with REAL cost/price, REAL on-hand stock (unsold inventory items),
-- stock aging buckets, and lead-time assumptions per distribution center.
-- Includes products that have stock but never sold (the most important dead-stock candidates).

CREATE OR REPLACE TABLE `inventory_risk_us.dim_product` AS
WITH prm AS (SELECT * FROM `inventory_risk_us.params`)

-- 1. Extract product catalog and unit economics
, product_base AS (
  SELECT
    CAST(id AS STRING) AS product_id,
    name AS description,
    category, brand, department,
    ROUND(cost, 2) AS unit_cost,
    ROUND(retail_price, 2) AS unit_price,
    ROUND(retail_price - cost, 2) AS unit_margin,
    SAFE_DIVIDE(cost, retail_price) AS cogs_ratio,
    distribution_center_id
  FROM `bigquery-public-data.thelook_ecommerce.products`
)

-- 2. Aggregate lifetime sales data
, sales AS (
  SELECT
    CAST(product_id AS STRING) AS product_id,
    COUNTIF(status != 'Cancelled') AS units_sold_lifetime,   
    COUNTIF(status = 'Returned') AS units_returned_lifetime,
    MIN(DATE(created_at)) AS first_sale_date,
    MAX(DATE(created_at)) AS last_sale_date
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
  GROUP BY product_id
)

-- 3. Analyze detailed physical inventory and aging buckets
, stock AS (
  SELECT
    CAST(i.product_id AS STRING) AS product_id,
    MIN(DATE(i.created_at)) AS first_stock_date,
    -- on hand = items received on/before as_of_date that have not been sold
    COUNTIF(i.sold_at IS NULL AND DATE(i.created_at) <= prm.as_of_date) AS on_hand_units,
    ROUND(AVG(IF(i.sold_at IS NULL AND DATE(i.created_at) <= prm.as_of_date,
                 DATE_DIFF(prm.as_of_date, DATE(i.created_at), DAY), NULL)), 1) AS avg_stock_age_days,
    COUNTIF(i.sold_at IS NULL AND DATE(i.created_at) <= prm.as_of_date
            AND DATE_DIFF(prm.as_of_date, DATE(i.created_at), DAY) < 90) AS units_age_lt90,
    COUNTIF(i.sold_at IS NULL AND DATE(i.created_at) <= prm.as_of_date
            AND DATE_DIFF(prm.as_of_date, DATE(i.created_at), DAY) BETWEEN 90 AND 180) AS units_age_90_180,
    COUNTIF(i.sold_at IS NULL AND DATE(i.created_at) <= prm.as_of_date
            AND DATE_DIFF(prm.as_of_date, DATE(i.created_at), DAY) > 180) AS units_age_gt180
  FROM `bigquery-public-data.thelook_ecommerce.inventory_items` i
  CROSS JOIN prm
  GROUP BY product_id
)

-- 4. Data joining and filtering
SELECT
  b.product_id, b.description, b.category, b.brand, b.department,
  b.unit_price, b.unit_cost, b.unit_margin, b.cogs_ratio,
  COALESCE(s.units_sold_lifetime, 0) AS units_sold_lifetime,
  COALESCE(s.units_returned_lifetime, 0) AS units_returned_lifetime,
  SAFE_DIVIDE(COALESCE(s.units_returned_lifetime, 0), NULLIF(s.units_sold_lifetime, 0)) AS return_rate,
  s.first_sale_date, s.last_sale_date,
  st.first_stock_date,
  COALESCE(st.on_hand_units, 0) AS on_hand_units,
  st.avg_stock_age_days,
  COALESCE(st.units_age_lt90, 0) AS units_age_lt90,
  COALESCE(st.units_age_90_180, 0) AS units_age_90_180,
  COALESCE(st.units_age_gt180, 0) AS units_age_gt180,
  CONCAT('DC_', CAST(b.distribution_center_id AS STRING)) AS distribution_center,
  COALESCE(lt.lead_time_days, 30) AS lead_time_days,        -- ASSUMPTION (see seed_dc_lead_time)
  COALESCE(lt.lead_time_std_days, 7) AS lead_time_std_days  -- ASSUMPTION
FROM product_base b
LEFT JOIN sales s USING (product_id)
LEFT JOIN stock st USING (product_id)
LEFT JOIN `inventory_risk_us.seed_dc_lead_time` lt ON lt.distribution_center_id = b.distribution_center_id
WHERE COALESCE(s.units_sold_lifetime, 0) > 0 OR COALESCE(st.on_hand_units, 0) > 0;