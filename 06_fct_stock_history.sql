--   Daily on-hand stock level for the highest-priority products over the last
--   90 days, next to each product's reorder point (ROP). It powers the
--   "stock level vs reorder point" line chart on the Stockout Watchlist page.
--   Seeing the stock line approach or cross the ROP line is far more intuitive
--   than a single days-of-cover number.
--
-- GRAIN
--   One row per product x day (200 products x 90 days = 18,000 rows).
--
-- HOW ON-HAND IS RECONSTRUCTED (point-in-time)
--   Each row of inventory_items is one physical unit with a received date
--   (created_at) and an optional sold date (sold_at). A unit counts as on hand
--   on day D when: received_date <= D AND (never sold OR sold_date > D).
--   Unlike the snapshot logic in 01_dim_product.sql (which uses "sold_at IS NULL"
--   = state today), this is correct for every historical day.
--
-- WHICH PRODUCTS ARE TRACKED
--   The top 200 in fct_risk_scoring, ordered by severity_rank, then by
--   total_cash_at_risk. Tracking every product would add millions of rows to the
--   dashboard for little value.
--
-- LIMITATIONS
--   * reorder_point_units is today's ROP, held constant across the 90 days
--     (historical ROPs are not reconstructed), so the ROP line is flat.
--   * The history is only available for the tracked products.
--
-- DEPENDS ON : params, fct_risk_scoring (run 00-04 first)
-- =============================================================================

CREATE OR REPLACE TABLE `inventory_risk_us.fct_stock_history` AS
WITH prm AS (SELECT * FROM `inventory_risk_us.params`)

-- 1. Products to track: highest severity first, then largest cash exposure
, watch AS (
  SELECT
    product_id, description, abc_class, risk_status, distribution_center,
    reorder_point_units
  FROM `inventory_risk_us.fct_risk_scoring`
  ORDER BY severity_rank, total_cash_at_risk DESC
  LIMIT 200
)

-- 2. Calendar: the 90 days ending on as_of_date
, days AS (
  SELECT day
  FROM prm,
       UNNEST(GENERATE_DATE_ARRAY(DATE_SUB(prm.as_of_date, INTERVAL 89 DAY), prm.as_of_date)) AS day
)

-- 3. Lifecycle of every physical unit of the tracked products
, items AS (
  SELECT
    CAST(product_id AS STRING) AS product_id,
    DATE(created_at) AS received_date,   -- unit entered the warehouse
    DATE(sold_at) AS sold_date           -- NULL = still unsold
  FROM `bigquery-public-data.thelook_ecommerce.inventory_items`
  WHERE CAST(product_id AS STRING) IN (SELECT product_id FROM watch)
)

-- 4. Count the units on hand for every product x day
SELECT
  w.product_id,
  CONCAT(w.product_id, ' | ', w.description) AS product_label,   -- label for the dashboard dropdown
  w.description,
  w.abc_class,
  w.risk_status,
  w.distribution_center,
  d.day,
  COUNTIF(it.received_date <= d.day
          AND (it.sold_date IS NULL OR it.sold_date > d.day)) AS on_hand_units,
  w.reorder_point_units
FROM watch w
CROSS JOIN days d
LEFT JOIN items it ON it.product_id = w.product_id
GROUP BY
  w.product_id, w.description, w.abc_class, w.risk_status,
  w.distribution_center, d.day, w.reorder_point_units;


-- =============================================================================
-- TABLE AND COLUMN DESCRIPTIONS (visible in the BigQuery schema tab and to
-- anyone browsing the dataset)
-- =============================================================================

ALTER TABLE `inventory_risk_us.fct_stock_history`
SET OPTIONS (description =
  'Daily on-hand stock vs reorder point for the top 200 priority products over the last 90 days. Grain: product x day. Source: thelook_ecommerce.inventory_items (point-in-time reconstruction) and fct_risk_scoring. Feeds the stock-level-vs-ROP chart on the Stockout Watchlist page.');

ALTER TABLE `inventory_risk_us.fct_stock_history`
ALTER COLUMN product_id SET OPTIONS (description =
  'Product identifier (STRING). Joins to dim_product and fct_risk_scoring.');

ALTER TABLE `inventory_risk_us.fct_stock_history`
ALTER COLUMN product_label SET OPTIONS (description =
  'Display label "product_id | description", used by the dashboard dropdown to select a product.');

ALTER TABLE `inventory_risk_us.fct_stock_history`
ALTER COLUMN description SET OPTIONS (description =
  'Product name.');

ALTER TABLE `inventory_risk_us.fct_stock_history`
ALTER COLUMN abc_class SET OPTIONS (description =
  'ABC class by 180-day revenue (A = top 80% of cumulative revenue, B = next 15%, C = rest, including products with no sales).');

ALTER TABLE `inventory_risk_us.fct_stock_history`
ALTER COLUMN risk_status SET OPTIONS (description =
  'Risk status as of as_of_date: CRITICAL_STOCKOUT, REORDER_NOW, DEAD_STOCK, OVERSTOCK or HEALTHY.');

ALTER TABLE `inventory_risk_us.fct_stock_history`
ALTER COLUMN distribution_center SET OPTIONS (description =
  'Distribution center the product is stocked at (DC_<id>). Lead times are assigned per distribution center (assumption, see seed_dc_lead_time).');

ALTER TABLE `inventory_risk_us.fct_stock_history`
ALTER COLUMN day SET OPTIONS (description =
  'Calendar day (DATE). Covers the 90 days ending on params.as_of_date.');

ALTER TABLE `inventory_risk_us.fct_stock_history`
ALTER COLUMN on_hand_units SET OPTIONS (description =
  'Units physically in stock at the end of that day: received on or before the day and not sold by the end of it (point-in-time).');

ALTER TABLE `inventory_risk_us.fct_stock_history`
ALTER COLUMN reorder_point_units SET OPTIONS (description =
  'Current reorder point in units (lead-time demand + safety stock), taken from fct_risk_scoring and constant across all days. Stock at or below this level triggers a reorder.');