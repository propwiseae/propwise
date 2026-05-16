-- ============================================================
-- PropWise · Dubai Transaction Data Table
-- Table: du_transaction_info
-- Naming convention: {city}_{business}_info
--   du          = Dubai
--   transaction = DLD sales, mortgages, gifts
-- Source: DLD open data — Excel exports + API (future)
-- Created: 2026
-- ============================================================

-- DROP TABLE IF EXISTS public.du_transaction_info;

CREATE TABLE IF NOT EXISTS public.du_transaction_info (

  -- ── Primary key ─────────────────────────────────────────
  id                    BIGSERIAL PRIMARY KEY,

  -- ── Data provenance ─────────────────────────────────────
  source                VARCHAR(10)   NOT NULL CHECK (source IN ('Excel', 'API')),
  source_ref            VARCHAR(255),
  data_period           VARCHAR(7),

  -- ── DLD transaction identifier ───────────────────────────
  -- e.g. '101-3-2026' — NOT unique per row (one transaction
  -- can cover multiple units in a portfolio registration)
  transaction_number    VARCHAR(50),

  -- ── Core transaction fields ──────────────────────────────
  instance_date         TIMESTAMPTZ,          -- INSTANCE_DATE (registration timestamp)

  -- Transaction group: 'Sales' | 'Mortgage' | 'Gifts'
  group_en              VARCHAR(30),          -- GROUP_EN

  -- Procedure detail: 34 distinct values e.g. 'Sale',
  -- 'Mortgage Registration', 'Sell - Pre registration'
  procedure_en          VARCHAR(150),         -- PROCEDURE_EN

  -- Off-plan status: 'Off-Plan' | 'Ready'
  is_offplan_en         VARCHAR(20),          -- IS_OFFPLAN_EN

  -- Freehold status: 'Free Hold' | 'Non Free Hold'
  is_free_hold_en       VARCHAR(20),          -- IS_FREE_HOLD_EN

  -- ── Location ────────────────────────────────────────────
  area_en               VARCHAR(255),         -- AREA_EN
  master_project_en     VARCHAR(255),         -- MASTER_PROJECT_EN (99.7% null in DLD data)
  project_en            VARCHAR(255),         -- PROJECT_EN

  nearest_metro_en      VARCHAR(255),         -- NEAREST_METRO_EN  (50% null)
  nearest_mall_en       VARCHAR(255),         -- NEAREST_MALL_EN   (51% null)
  nearest_landmark_en   VARCHAR(255),         -- NEAREST_LANDMARK_EN (38% null)

  -- ── Property details ────────────────────────────────────
  usage_en              VARCHAR(50),          -- USAGE_EN: 'Residential' | 'Commercial'
  prop_type_en          VARCHAR(50),          -- PROP_TYPE_EN: Unit | Building | Land
  prop_sb_type_en       VARCHAR(100),         -- PROP_SB_TYPE_EN: Flat | Villa | Office | Shop…

  -- Rooms: text field in DLD data e.g. '3 B/R', 'Studio', 'Office'
  rooms_en              VARCHAR(20),          -- ROOMS_EN

  parking               SMALLINT,             -- PARKING (spaces; NULL when not provided)

  -- DLD files two area figures:
  -- procedure_area = area registered in the transaction deed
  -- actual_area    = physical built area (sqft)
  procedure_area        NUMERIC(18, 4),       -- PROCEDURE_AREA (sqft)
  actual_area           NUMERIC(18, 4),       -- ACTUAL_AREA    (sqft)

  -- ── Financial fields ────────────────────────────────────
  -- Transaction value in AED
  trans_value           NUMERIC(18, 2),       -- TRANS_VALUE

  -- Buyer / seller count (portfolio transactions have 0 for both)
  total_buyer           SMALLINT,             -- TOTAL_BUYER
  total_seller          SMALLINT,             -- TOTAL_SELLER

  -- ── Computed / derived fields ────────────────────────────
  trans_value_usd       NUMERIC(18, 2)        GENERATED ALWAYS AS (trans_value / 3.6725) STORED,

  -- Price per sqft (AED) — key metric for PropWise yield calc
  price_per_sqft_aed    NUMERIC(12, 2)        GENERATED ALWAYS AS (
                            CASE WHEN actual_area > 0
                              THEN ROUND((trans_value / actual_area)::NUMERIC, 2)
                            ELSE NULL END
                          ) STORED,

  -- ── Audit ───────────────────────────────────────────────
  created_at            TIMESTAMPTZ           NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ           NOT NULL DEFAULT NOW()

);

-- ============================================================
-- Indexes — tuned for PropWise query patterns
-- ============================================================

-- Area filter — most common query dimension
CREATE INDEX IF NOT EXISTS idx_du_trans_area
  ON public.du_transaction_info (area_en);

-- Date-range queries (monthly dashboard, weekly refresh)
CREATE INDEX IF NOT EXISTS idx_du_trans_instance_date
  ON public.du_transaction_info (instance_date DESC);

-- Transaction type filters (Sales vs Mortgage vs Gifts)
CREATE INDEX IF NOT EXISTS idx_du_trans_group
  ON public.du_transaction_info (group_en);

-- Off-plan vs ready filter (critical for PropWise off-plan tracker)
CREATE INDEX IF NOT EXISTS idx_du_trans_offplan
  ON public.du_transaction_info (is_offplan_en);

-- Property type filters
CREATE INDEX IF NOT EXISTS idx_du_trans_prop_type
  ON public.du_transaction_info (prop_type_en, prop_sb_type_en);

-- Transaction number lookup (DLD price checker feature)
CREATE INDEX IF NOT EXISTS idx_du_trans_number
  ON public.du_transaction_info (transaction_number);

-- Source traceability
CREATE INDEX IF NOT EXISTS idx_du_trans_source
  ON public.du_transaction_info (source, data_period);

-- Composite for capital appreciation query: area + date + usage
CREATE INDEX IF NOT EXISTS idx_du_trans_appreciation
  ON public.du_transaction_info (area_en, usage_en, instance_date DESC);

-- Composite for price-per-sqft heatmap: area + prop type + date
CREATE INDEX IF NOT EXISTS idx_du_trans_price_heatmap
  ON public.du_transaction_info (area_en, prop_sb_type_en, instance_date DESC);

-- ============================================================
-- Auto-update updated_at on row change
-- (reuses the function created by du_rent_info if already exists)
-- ============================================================

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_du_trans_updated_at ON public.du_transaction_info;
CREATE TRIGGER trg_du_trans_updated_at
  BEFORE UPDATE ON public.du_transaction_info
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ============================================================
-- Row Level Security (RLS)
-- ============================================================

ALTER TABLE public.du_transaction_info ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users can read du_transaction_info"
  ON public.du_transaction_info
  FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "Service role can manage du_transaction_info"
  ON public.du_transaction_info
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- ============================================================
-- Analytics view — capital appreciation by area
-- (feeds PropWise capital appreciation tracker feature)
-- ============================================================

CREATE OR REPLACE VIEW public.vw_du_trans_area_summary AS
SELECT
  area_en,
  usage_en,
  prop_sb_type_en,
  is_offplan_en,
  data_period,
  COUNT(*)                                                          AS transaction_count,
  ROUND(AVG(trans_value))                                           AS avg_trans_value_aed,
  ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY trans_value))  AS median_trans_value_aed,
  ROUND(AVG(price_per_sqft_aed), 2)                                AS avg_price_per_sqft_aed,
  ROUND(AVG(actual_area), 1)                                       AS avg_area_sqft,
  MIN(trans_value)                                                  AS min_trans_value_aed,
  MAX(trans_value)                                                  AS max_trans_value_aed,
  SUM(trans_value)                                                  AS total_volume_aed
FROM public.du_transaction_info
WHERE trans_value > 0
  AND actual_area > 0
  AND group_en = 'Sales'
GROUP BY area_en, usage_en, prop_sb_type_en, is_offplan_en, data_period;

GRANT SELECT ON public.vw_du_trans_area_summary TO authenticated;

-- ============================================================
-- Comments
-- ============================================================

COMMENT ON TABLE public.du_transaction_info IS
  'Dubai property transactions from DLD open data. Covers sales, mortgages, and gifts. Naming: du=Dubai, transaction=business domain.';

COMMENT ON COLUMN public.du_transaction_info.transaction_number IS
  'DLD transaction reference e.g. 101-3-2026. NOT unique per row — portfolio registrations share one number across multiple units.';
COMMENT ON COLUMN public.du_transaction_info.group_en IS
  'Transaction category: Sales | Mortgage | Gifts.';
COMMENT ON COLUMN public.du_transaction_info.procedure_en IS
  'Detailed procedure type. 34 distinct values including Sale, Mortgage Registration, Sell - Pre registration etc.';
COMMENT ON COLUMN public.du_transaction_info.is_offplan_en IS
  'Off-Plan = not yet built/handed over. Ready = completed property.';
COMMENT ON COLUMN public.du_transaction_info.trans_value IS
  'Transaction value in AED as filed with DLD.';
COMMENT ON COLUMN public.du_transaction_info.price_per_sqft_aed IS
  'Auto-computed: trans_value / actual_area. NULL when actual_area is 0. Key metric for yield calculator.';
COMMENT ON COLUMN public.du_transaction_info.procedure_area IS
  'Area as registered in the transaction deed (sqft). May differ slightly from actual_area.';
COMMENT ON COLUMN public.du_transaction_info.rooms_en IS
  'DLD text field: 1 B/R, 2 B/R, 3 B/R, Studio, Office, Shop etc.';
COMMENT ON COLUMN public.du_transaction_info.source IS
  'Excel = imported from DLD monthly CSV/Excel. API = ingested via DLD live API (Year 2+).';
