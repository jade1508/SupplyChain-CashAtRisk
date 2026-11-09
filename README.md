<img width="1440" height="807" alt="image" src="https://github.com/user-attachments/assets/f7f0bc2a-68c3-4c63-9162-c77bc2e8b1c9" /># 📦 Supply Chain Inventory & Cash-at-Risk Early-Warning System

> **Most inventory dashboards tell you what already happened. This one shows where your cash is buried, which products to reorder, and by when.**

▶️ **[Watch the demo (screen recording)](https://youtu.be/kZpnBolfdeQ)**: the Power BI dashboard with live filters, and the Make.com workflow running end to end.

<img width="1443" height="806" alt="image" src="https://github.com/user-attachments/assets/bd6a6149-3698-4fe9-b60d-fe1508b987b8" />


**What it does**

1. **Quantifies working-capital risk on both sides of inventory:** cash buried in excess stock *and* margin at risk from potential stockouts.
2. **Turns it into a ranked action list:** which products to reorder, how many units, the deadline to order, and which products will reach their reorder point within 14 days.
3. **Delivers a plain-language briefing to Slack and email every weekday at 07:00**, so nobody has to open a dashboard to find out what needs attention.

**Built with:** Google BigQuery (SQL) · Power BI (DAX) · Make.com · OpenAI API · GitHub

---

## 1. Business Context

Inventory misallocation is costly in two opposite directions:

| Failure mode | Cost |
|---|---|
| **Understocking (stockouts)** | Lost margin, lost customers, lost momentum in peak periods |
| **Overstocking (dead stock)** | Capital stuck in the warehouse, holding costs, future markdown losses |

Most operational dashboards stop at unit counts ("4 SKUs below reorder point"). This project evaluates inventory through a **working-capital lens** and tracks the two sides separately, because they live on different scales:

- **Cash buried** (a stock): value at cost of units beyond 90 days of projected demand.
- **Margin at risk** (a flow): expected margin lost to stockouts per replenishment cycle.

`total_cash_at_risk` (their sum) stays in the data as a per-product ranking key, but it is not a headline KPI: on an overstocked portfolio it is dominated by cash buried.

---

## 2. Data & Assumptions

**Source:** `bigquery-public-data.thelook_ecommerce` (a synthetic e-commerce dataset). Tables used: `products`, `order_items`, `inventory_items`.

| Element | Source |
|---|---|
| Unit cost, retail price, margin | ✅ Real (dataset) |
| **On-hand stock** (items received but not yet sold) and stock age | ✅ Real (dataset, `inventory_items`) |
| Sales, cancellations, returns | ✅ Real (dataset, `order_items`) |
| Lead time and lead-time variability | 🔶 **Assumption**, assigned per distribution center (`seed_dc_lead_time`) |
| On-order quantity | 🔶 **Assumption**: not available, treated as 0 |

**Currency:** all monetary values are in **US dollars ($)**. The dataset does not state a currency; USD is assumed.

> ⚠️ **Setup note:** the public dataset is stored in the **US** location. Your own `inventory_risk_us` dataset must also be created in **US**, otherwise queries fail with access/not-found errors.
>
> ⚠️ The public dataset is refreshed periodically, so results change between runs. `as_of_date` is derived from the data (latest order date), not from `CURRENT_DATE()`. For fully reproducible results, copy the three source tables into your own dataset first.

---

## 3. Architecture

```text
[BigQuery public dataset: thelook_ecommerce]
        │  products · order_items · inventory_items
        ▼
🥈 SILVER   params ─► dim_product ─► fct_daily_demand ─► fct_demand_stats
        │            (real stock,     (calendar spine,     (seasonality, ABC-XYZ,
        │             cost, aging)     zero-demand days)    projected demand)
        ▼
🥇 GOLD     fct_risk_scoring ─► fct_stock_history
            (safety stock, ROP, stockout probability,   (90-day stock vs ROP
             cash at risk, status, order deadline)       for top 200 products)
        │
   ┌────┴───────────────────────────────┐
   ▼                                    ▼
📊 Power BI dashboard (3 pages)    ⚡ Make.com alert pipeline
                                   (scheduled query ➔ AI summary ➔ Slack / email)
```

---

## 4. SQL Pipeline

Run in this order (all files are in [`sql/`](sql/)):

| File | Output table | What it does |
|---|---|---|
| `00_params.sql` | `params`, `seed_dc_lead_time` | Run parameters (`as_of_date`, window, thresholds such as `overstock_days` and `reorder_soon_days`) and the lead-time assumption per distribution center |
| `01_dim_product.sql` | `dim_product` | One row per product: price, cost, margin, sales and returns, **on-hand units**, stock age buckets (<90, 90 to 180, >180 days), lead time. Includes products with stock that never sold |
| `02_fct_daily_demand.sql` | `fct_daily_demand` | Daily demand per product for the last 365 days with a **calendar spine** so zero-demand days are kept |
| `03_fct_demand_stats.sql` | `fct_demand_stats` | 180-day demand statistics, category-level seasonality, de-seasonalised projection, ABC-XYZ classes, demand pattern |
| `04_fct_risk_scoring.sql` | `fct_risk_scoring` | Safety stock, reorder point, days until reorder point, stockout probability, cash at risk, status, order deadline and quantity |
| `05_diagnostics.sql` | (queries only) | Reconciliation, sanity checks and a Poisson cross-check of the stockout figures |
| `06_fct_stock_history.sql` | `fct_stock_history` | Daily on-hand stock vs reorder point for the top 200 priority products over 90 days (point-in-time reconstruction) |

### Key design decisions

- **Real on-hand stock.** Stock comes from unsold `inventory_items`, so the risk scores are driven by actual inventory, not by a formula that assumes it.
- **Demand definition.** Demand = units ordered and not cancelled. Returns do not reduce demand (returned items are kept in `returned_units` for reference).
- **Calendar spine from first stock date.** Zero-demand days are preserved (otherwise variance is understated), but a product is not charged for days before it existed.
- **Seasonality at category level, de-trended.** Product-level demand is too sparse to estimate seasonality, and the shop grows over time. Each month's daily rate is normalised by its own calendar year's average, using complete years only, then clamped to [0.5, 2.0].
- **De-seasonalise, then project.** Window average ÷ window seasonal index = base demand; base demand × next-month index = projected demand.
- **Point-in-time stock history.** A unit counts as on hand on day D if it was received on or before D and not sold by the end of D, so the history is correct for every past day.
- **Early-warning tier.** `REORDER_NOW` only lists products that are already at or below their reorder point, so their order deadlines are in the past by construction. `REORDER_SOON` adds the forward-looking signal: `days_until_rop = (on hand − ROP) / projected daily demand`, flagged when it is ≤ `reorder_soon_days` (14). The horizon is a parameter, not a tuned value (see Key Findings for how many products fall in 14, 30 and 60 days).

### Inventory formulas

Lead-time demand variability combines **demand volatility** ($\sigma_d$) and **lead-time variability** ($\sigma_L$):

$$\sigma_{LT} = \sqrt{L \cdot \sigma_d^2 + \mu_d^2 \cdot \sigma_L^2}$$

$$SS = z \cdot \sigma_{LT} \qquad ROP = \mu_d \cdot L + SS$$

Service level $z$ depends on ABC class: **A = 98% (z = 2.054), B = 95% (1.645), C = 90% (1.282)**.

Stockout probability and expected shortage use the standard normal loss function $G(z)=\varphi(z)-z\,(1-\Phi(z))$:

$$z_{stat} = \frac{\text{inventory position} - \mu_d L}{\sigma_{LT}} \qquad \text{margin at risk} = \sigma_{LT} \cdot G(z_{stat}) \cdot \text{unit margin}$$

$$\text{cash buried} = \max(\text{on hand} - 90 \text{ days of projected demand},\ 0) \times \text{unit cost}$$

### ABC-XYZ segmentation

| Dimension | Basis | Classes |
|---|---|---|
| **ABC** (value) | Cumulative share of 180-day revenue | A ≤ 80%, B ≤ 95%, C = rest (zero revenue = C) |
| **XYZ** (predictability) | Coefficient of variation = σ / μ | X ≤ 0.5, Y ≤ 1.0, Z > 1.0 (no demand = Z) |

These cutoffs are widely used **conventions, not universal standards**; sources disagree (some use much tighter XYZ bands). See [References](#10-references). A `demand_pattern` flag (`REGULAR`, `INTERMITTENT`, `NO_DEMAND`) marks products where the statistics are weak.

### Risk status rules (evaluated in order)

| Status | Rule |
|---|---|
| `CRITICAL_STOCKOUT` | On hand ≤ ROP, projected demand > 0, **class A** |
| `REORDER_NOW` | On hand ≤ ROP, projected demand > 0 |
| `REORDER_SOON` | On hand > ROP, projected demand > 0, and `(on hand − ROP) / projected daily demand` ≤ `reorder_soon_days` (default 14) |
| `DEAD_STOCK` | No sale in the demand window (days of cover capped at 9999) and cash buried > 0 |
| `SEVERE_OVERSTOCK` | On hand > 0 and days of cover > 730 (more than 2 years of stock) |
| `OVERSTOCK` | On hand > 0 and days of cover > 365 (`overstock_days`) |
| `HEALTHY` | Otherwise |

`overstock_days` and `reorder_soon_days` live in the `params` table; the 730-day tier is written in `04_fct_risk_scoring.sql`. The tiers were recalibrated after the diagnostics showed that conventional 120/180-day thresholds classified 99.8% of this dataset as dead stock (see Key Findings).

---

## 5. Dashboard (Power BI, 3 pages)

### Screenshots

<img width="1443" height="809" alt="image" src="https://github.com/user-attachments/assets/a27e551b-aac9-49a2-8bf5-5549694b5fa4" />
<img width="1444" height="809" alt="image" src="https://github.com/user-attachments/assets/f6ec14d1-2c27-49c4-a615-a6f048cd8c2c" />
<img width="1440" height="807" alt="image" src="https://github.com/user-attachments/assets/b4420378-ef5b-48d4-b445-3fe1135c6ee2" />

### Data model

Tables loaded (BigQuery connector, Import mode): `fct_risk_scoring`, `dim_product`, `fct_stock_history`. Two small helper tables are created in Power BI (*Enter data*): `Age Buckets` and `Measures`.

| Relationship | Type |
|---|---|
| `dim_product[product_id]` → `fct_risk_scoring[product_id]` | One-to-one, used by `RELATED()` for unit cost and price |
| `fct_risk_scoring[product_id]` → `fct_stock_history[product_id]` | One-to-many, so selecting a product in the watchlist filters the stock chart |

### Page 1: Executive Cash-at-Risk

- **Executive headline banner** (DAX, see below): one sentence combining cash buried, overdue and soon-due reorders, and the break-even markdown.
- **KPI cards:** Cash Buried % Inventory · Cash Buried · Total Inventory Value · Weighted Days of Cover · Products Needing Order. Margin at risk lives on the Stockout Watchlist page, next to the products it applies to.
- **Scatter, by category and ABC class:** one bubble per category and ABC class. X = weighted days of cover, Y = inventory value, bubble size = cash buried, colour = ABC class. Aggregated on purpose: at product level the $8.8M is spread over 29k products averaging about $300 each, which gives a dense, unreadable cloud (the product-level view lives in the watchlist and Top 10 tables). X excludes products with no demand (days of cover capped at 9999), while Y includes them.
- **Column chart by distribution center:** cash buried. The share of inventory that is cash buried is about 93% in every distribution center, so a % line adds nothing and was dropped.
- **Slicers:** date range, distribution center, category, brand, product id, ABC class, risk status.

### Page 2: Stockout Watchlist

- **Page 2** filtered to `CRITICAL_STOCKOUT`, `REORDER_NOW` and `REORDER_SOON`. In the current run all 19 products in the first two tiers are already past their order deadline; `REORDER_SOON` rows have a deadline within the next 14 days (positive days to deadline).
- **Cards:** critical products, reorder now, reorder soon, order value at cost, margin at risk (next replenishment cycle).
- **Table** sorted by `severity_rank`, then `total_cash_at_risk` (descending). Columns: product, distribution center, ABC class, days of cover, on hand, reorder point, suggested order quantity, order deadline, days to deadline, margin at risk. Conditional formatting: days to deadline ≤ 0 red, ≤ 7 amber; data bars on margin at risk.
- **Stock level vs reorder point (line chart, 90 days):** `fct_stock_history[day]` on the axis, on-hand units and reorder point as lines. Select a row in the table to see that product. The reorder point is today's value, so it is a flat line. The chart title is a DAX measure (`Fell Below ROP Label`): it asks for a product until a row is selected, then reads e.g. "Fell below ROP on 10 Sep", the day on-hand dropped below today's reorder point.

### Page 3: Dead Stock & Aging

- **Page 3** filtered out `HEALTHY`, so its totals are slightly below page 1.
- **Markdown what-if:** two sliders, markdown % (0% to 80%) and sell-through % (0% to 100%). Cards show dead stock book value, cash recovered at the chosen sell-through, and gain/loss versus book value. A text line beside the sliders shows the break-even sell-through ("87% of units must sell", or "Not achievable at this markdown"); the break-even markdown (about 52% if everything sells) is in the Page 1 headline. Sell-through is a scenario assumption, not a forecast: dead stock has no sales in the window by definition.
- **Treemap:** cash buried by ABC class. (An ABC × XYZ matrix would be a single column, because every product is class Z in the current run; see Key Findings.)
- **Aging buckets (donut chart):** stock value in <90, 90 to 180, >180 days.
- **Top 10 table** by cash buried: product, category, distribution center, on hand, stock age (days), cash buried.

### Example DAX measures

```dax
Total Cash at Risk       = SUM(fct_risk_scoring[total_cash_at_risk])
Cash Buried              = SUM(fct_risk_scoring[cash_buried])
Margin at Risk           = SUM(fct_risk_scoring[margin_at_risk])
Total Inventory Value    = SUM(fct_risk_scoring[inventory_value])
Cash Buried % Inventory  = DIVIDE([Cash Buried], [Total Inventory Value])

// Products with no demand have days_of_cover capped at 9999; exclude them to avoid distorting the average
Weighted Days of Cover =
VAR Active = FILTER(fct_risk_scoring, fct_risk_scoring[days_of_cover] < 9999)
RETURN DIVIDE(
    SUMX(Active, fct_risk_scoring[days_of_cover] * fct_risk_scoring[inventory_value]),
    SUMX(Active, fct_risk_scoring[inventory_value])
)

Products Needing Order =
CALCULATE(COUNTROWS(fct_risk_scoring),
          fct_risk_scoring[risk_status] IN {"CRITICAL_STOCKOUT", "REORDER_NOW"})

Order Value at Cost =
SUMX(fct_risk_scoring, fct_risk_scoring[suggested_order_qty] * RELATED(dim_product[unit_cost]))

Days to Deadline =
DATEDIFF(MAX(fct_risk_scoring[as_of_date]), MAX(fct_risk_scoring[order_deadline_date]), DAY)

Products Reorder Soon =
CALCULATE(COUNTROWS(fct_risk_scoring), fct_risk_scoring[risk_status] = "REORDER_SOON")

Critical A-class =
CALCULATE(COUNTROWS(fct_risk_scoring), fct_risk_scoring[risk_status] = "CRITICAL_STOCKOUT")

Products Overdue =
VAR AsOf = MAX(fct_risk_scoring[as_of_date])
RETURN CALCULATE(
    COUNTROWS(fct_risk_scoring),
    fct_risk_scoring[risk_status] IN {"CRITICAL_STOCKOUT", "REORDER_NOW"},
    fct_risk_scoring[order_deadline_date] < AsOf
)

// Title of the stock-vs-ROP chart on page 2 (the reorder point in fct_stock_history is today's value, flat over 90 days)
Fell Below ROP Label =
VAR LastDay = MAX(fct_stock_history[day])
VAR LastAbove =
    CALCULATE(
        MAX(fct_stock_history[day]),
        FILTER(fct_stock_history,
               fct_stock_history[on_hand_units] >= fct_stock_history[reorder_point_units])
    )
VAR BelowNow =
    COUNTROWS(FILTER(fct_stock_history,
        fct_stock_history[day] = LastDay
            && fct_stock_history[on_hand_units] < fct_stock_history[reorder_point_units])) > 0
RETURN
IF(NOT HASONEVALUE(fct_stock_history[product_id]),
   "Select one product from the table",
   IF(NOT BelowNow,
      "At or above reorder point as of " & FORMAT(LastDay, "d mmm", "en-US"),
      IF(ISBLANK(LastAbove),
         "Below ROP for the whole 90 days shown",
         "Fell below ROP on " & FORMAT(LastAbove + 1, "d mmm", "en-US"))))

// Aging buckets (Age Buckets is a helper table with one column "Bucket": "<90 days", "90-180 days", ">180 days")
Aged Stock Value =
SWITCH(SELECTEDVALUE('Age Buckets'[Bucket]),
    "<90 days",    SUMX(fct_risk_scoring, fct_risk_scoring[units_age_lt90]    * RELATED(dim_product[unit_cost])),
    "90-180 days", SUMX(fct_risk_scoring, fct_risk_scoring[units_age_90_180]  * RELATED(dim_product[unit_cost])),
    ">180 days",   SUMX(fct_risk_scoring, fct_risk_scoring[units_age_gt180]   * RELATED(dim_product[unit_cost]))
)

// Markdown what-if: [Markdown % Value] is generated by a Power BI "What-if" parameter (0 to 0.8, step 0.05, default 0.4)
Dead Stock Book Value =
SUMX(FILTER(fct_risk_scoring, fct_risk_scoring[risk_status] = "DEAD_STOCK"),
     fct_risk_scoring[on_hand_units] * RELATED(dim_product[unit_cost]))

// Assumes all dead stock can be sold at the markdown (an upper bound)
Cash Recoverable at Markdown =
SUMX(FILTER(fct_risk_scoring, fct_risk_scoring[risk_status] = "DEAD_STOCK"),
     fct_risk_scoring[on_hand_units] * RELATED(dim_product[unit_price]) * (1 - [Markdown % Value]))

Markdown Gain/Loss vs Cost = [Cash Recoverable at Markdown] - [Dead Stock Book Value]

// Break-even and sell-through. [Sell-through % Value] is a second What-if parameter (0 to 1, step 0.05, default 0.3).
// It is a scenario assumption: dead stock has no sales in the window, so no observed rate exists.
Dead Stock Value at Full Price =
SUMX(FILTER(fct_risk_scoring, fct_risk_scoring[risk_status] = "DEAD_STOCK"),
     fct_risk_scoring[on_hand_units] * RELATED(dim_product[unit_price]))

// Largest markdown that still breaks even if 100% of dead stock sells
Break-even Markdown % =
1 - DIVIDE([Dead Stock Book Value], [Dead Stock Value at Full Price])

Cash Recovered (Sell-through) =
[Dead Stock Value at Full Price] * (1 - [Markdown % Value]) * [Sell-through % Value]

// Unsold units stay on the books, so compare against the full book value
Markdown Gain/Loss (Sell-through) =
[Cash Recovered (Sell-through)] - [Dead Stock Book Value]

// Share of units that must sell at the chosen markdown to recover book value; BLANK if above 100%
Break-even Sell-through % =
VAR s = DIVIDE([Dead Stock Book Value],
               [Dead Stock Value at Full Price] * (1 - [Markdown % Value]))
RETURN IF(s > 1, BLANK(), s)

Break-even Status =
IF(ISBLANK([Break-even Sell-through %]),
   "Not achievable at this markdown",
   FORMAT([Break-even Sell-through %], "0%") & " of units must sell")

Executive Headline =
VAR Buried  = "$" & FORMAT(DIVIDE([Cash Buried], 1000000), "0.00") & "M"
VAR Pct     = FORMAT([Cash Buried % Inventory], "0%")
VAR Overdue = [Products Overdue]
VAR Crit    = [Critical A-class]
VAR Soon    = [Products Reorder Soon]
VAR BE      = [Break-even Markdown %]
VAR Line1 = Buried & " (" & Pct & " of inventory at cost) is buried in excess stock."
VAR Line2 =
    IF(Overdue + Soon = 0,
       "No products are at or near their reorder point.",
       Overdue & " products are already past their order deadline"
         & IF(Crit > 0, " (" & Crit & " A-class)", "")
         & IF(Soon > 0, ", " & Soon & " more will hit reorder point within 14 days.", "."))
VAR Line3 =
    IF(ISBLANK(BE) || BE <= 0, "",
       " Markdown only breaks even below a " & FORMAT(BE, "0%")
         & " discount, and only if all dead stock sells.")
RETURN Line1 & " " & Line2 & Line3
```

---

## 6. Automated Alerts (Make.com)

```text
[1. Schedule: Mon-Fri 07:00]
        ▼
[2. BigQuery module] ➔ top 25 products needing action
        ▼
[3. Array aggregator] ➔ JSON payload
        ▼
[4. OpenAI module] ➔ 4-sentence executive briefing
        ▼
[5. Slack #supply-chain]     [6. Email to Ops & Finance leads]
```

Query for step 2:

```sql
SELECT product_id, description, distribution_center, abc_class, days_of_cover,
       margin_at_risk, suggested_order_qty, order_deadline_date, total_cash_at_risk
FROM `inventory_risk_us.fct_risk_scoring`
WHERE risk_status IN ('CRITICAL_STOCKOUT', 'REORDER_NOW', 'REORDER_SOON')
ORDER BY severity_rank, total_cash_at_risk DESC
LIMIT 25;
```

Email table fields: `product_id`, `description`, `days_of_cover`, `margin_at_risk`, `suggested_order_qty`, `order_deadline_date`.

> All numbers are computed deterministically in SQL; the AI step only writes the narrative.
> **Staleness guard.** The data layer is a snapshot as of `as_of_date` (the latest order in the dataset, currently 2026-11-01), while the alert runs on the calendar date. 
> If a `REORDER_SOON` product's order deadline has already passed on the day the email is sent, the email shows it as `REORDER_NOW` (overdue). The underlying tables and the Power BI dashboard are not changed, so the dashboard keeps the original `risk_status`.
> In production, the data layer would be rebuilt on a daily schedule before the alert runs, and this guard would rarely trigger.

The full run (trigger → Slack message and email arriving) is shown in the [demo video]({{FILL: YouTube URL}}).

---

## 7. Key Findings

Latest run (data as of 2026-11-01, the latest order in the dataset): 29,056 products, 180-day demand window.

| Check | Result |
|---|---|
| Status mix | 27% `DEAD_STOCK` (7,738, no sale in the window) · 52% `SEVERE_OVERSTOCK` (15,241) · 18% `OVERSTOCK` (5,369) · 2% `HEALTHY` (684) · 19 products at or below their reorder point (7 `CRITICAL_STOCKOUT`, 12 `REORDER_NOW`) · 5 `REORDER_SOON` |
| Cash buried | ≈ $8.16M, or 92.6% of the $8.80M inventory at cost |
| Where the cash sits | About 93% of inventory value is cash buried in every distribution center (≈ $0.5M to $1.2M each, DC_3 highest), so the issue is portfolio-wide rather than local |
| Margin at risk | ≈ $15.99 across the 19 products below their reorder point (normal approximation, expected shortage per replenishment cycle); ≈ $16 including the 5 `REORDER_SOON` products |
| Reorder horizon | 5 products reach their reorder point within 14 days (the default), 6 within 30 and 24 within 60. 14 days is kept: it gives a short, actionable list, and 60 days is too far out to be a warning |
| Dead stock break-even | Book value ≈ $1.82M against ≈ $3.8M at full price. Markdown breaks even only below ≈ 52%, and only if all dead stock sells; even with no markdown about 48% of units must sell. At 30% sell-through no markdown level recovers book value |
| Poisson cross-check | On the products below their reorder point, margin at risk is ≈ $20 under a Poisson model vs ≈ $16 under the normal approximation: same order of magnitude, so the overstock-dominates conclusion does not depend on the model. The normal model gives roughly 2 to 3 times the Poisson stockout probability, so probabilities are used for ranking only. These products hold 1 to 2 units against an expected lead-time demand of 0.2 to 0.8 units |
| Demand pattern | 73% `INTERMITTENT`, 27% `NO_DEMAND`, 0 `REGULAR`; every product falls in XYZ class Z |
| Reconciliation | 180,746 inventory units marked sold = 180,746 order items (1:1 match); 27,077 of them belong to cancelled orders |

**Reading the results.** On this shop the story is overstock, not stockout: stock far exceeds demand (median days of cover ≈ 3.5 years), so cash buried outweighs expected stockout losses by several orders of magnitude, and the actionable signal is *where* the cash sits (status tier, stock age, distribution center, category). Conventional 120/180-day thresholds put 99.8% of products in dead stock, so the tiers were recalibrated to this dataset. The stockout side is kept as a short watchlist: 19 products already at or below their reorder point (all past their order deadline) plus 5 about to reach it. Markdown alone does not solve dead stock; recovering book value needs roughly half the units to sell close to full price.

---

## 8. Limitations

- **Synthetic data.** About 63% of inventory items are unsold, so results skew towards overstock; status tiers were calibrated to this dataset. Read the findings as a demonstration of the method, not as business conclusions.
- **Assumed inputs.** Lead times are assigned per distribution center and on-order quantity is treated as 0.
- **Sparse demand.** No product has regular demand, so the normal approximation behind `stockout_probability` and `margin_at_risk` is weak. Treat both as ranking signals: a Poisson cross-check on the flagged products gives the same order of magnitude (see Key Findings), while Croston-type or count-based models would be the rigorous route. For the same reason every product lands in XYZ class Z.
- **Reorder-soon horizon.** `days_until_rop` assumes constant projected demand. With intermittent demand a few units can move it by weeks, so the 14-day tier is a prioritisation signal, not a forecast.
- **Markdown what-if.** Sell-through is a scenario assumption (no observed rate exists for products with no sales), and the model ignores selling and holding costs. Read the break-even figures as thresholds, not predictions.
- **Stock definition.** `inventory_items.sold_at` is also set for cancelled orders (27,077 units), so on-hand stock is slightly understated. On-hand is a snapshot of the current dataset state; only `fct_stock_history` is point-in-time.
- **Scope and conventions.** Stock history covers the top 200 products over 90 days with today's reorder point as a flat line. ABC/XYZ cutoffs are conventions, and ABC uses a 180-day window.
- **Snapshot vs alert date.** The public dataset is not updated daily, so  `as_of_date` lags the send date. The email applies a staleness guard (see section 6); the dashboard does not, so counts can differ slightly between the two.

---

## 9. How to Run

1. Create a BigQuery dataset named `inventory_risk_us` in the **US** location.
2. Run `sql/00_params.sql` through `sql/04_fct_risk_scoring.sql` in order.
3. Run the queries in `sql/05_diagnostics.sql` and review the status mix.
4. Run `sql/06_fct_stock_history.sql`.

That reproduces the full data layer. The dashboard and the alert workflow are documented in sections 5 and 6 and shown in the demo video; the data model and DAX above are enough to rebuild the report in Power BI. Happy to walk through the Power BI file and the Make.com scenario live.

### Repository structure

```text
├── README.md
├── sql/            # 00_params.sql ... 06_fct_stock_history.sql
├── dashboard/      # screenshots / GIF
└── docs/           # assumptions and sensitivity notes
```

---

## 10. References

**Segmentation (ABC-XYZ)**
- ABC analysis (Pareto, 80/95 convention, service-level targets by class): [MetricGate: ABC Analysis](https://metricgate.com/docs/abc-analysis-pareto-inventory/) · [SYSPRO documentation](https://help.syspro.com/syspro-7-update-1/invp50.htm)
- XYZ demand classification (coefficient of variation, default thresholds 0.5 / 1.0): [MetricGate: XYZ Demand Classification](https://metricgate.com/docs/xyz-demand-classification/) · [Cleverence](https://www.cleverence.com/articles/for-business/xyz-inventory-analysis-4831/) · [Mecalux (alternative, tighter thresholds)](https://www.mecalux.com/blog/abc-xyz)

**Safety stock, reorder point and service level**
- Safety stock with demand and lead-time uncertainty, reorder point, limits of the normal distribution: [ABC Supply Chain: Safety Stock Formula & Calculation](https://abcsupplychain.com/safety-stock-formula-calculation/)
- Standard normal loss function and expected shortage per cycle (`σ_LT · G(z)`): [MetricGate: Cycle Service Level vs Fill Rate](https://metricgate.com/docs/service-level-fill-rate/)

**Normal CDF in SQL**
- Logistic approximation of the cumulative normal (BigQuery has no built-in normal CDF): Bowling, Khasawneh, Kaewkuekool & Cho (2009), [A logistic approximation to the cumulative normal distribution](https://jiem.org/index.php/jiem/article/view/60), *Journal of Industrial Engineering and Management* 2(1), 114-127

**Data**
- Dataset: BigQuery public dataset `bigquery-public-data.thelook_ecommerce`

---

**Author:** Jade Le · [Portfolio](https://dataanalystjade.wordpress.com/) · [GitHub](https://github.com/jade1508) · [LinkedIn]({{FILL: LinkedIn URL}})
