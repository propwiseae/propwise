-- ============================================================
-- PropWise · Dubai Rent Data Table
-- Table: du_rent_info
-- Naming convention: {city}_{business}_info
--   du  = Dubai
--   rent = DLD rental contracts
-- Source: DLD open data — Excel exports + API (future)
-- Created: 2026
-- ============================================================

-- Drop if re-running during dev (comment out in production)
-- DROP TABLE IF EXISTS public.du_rent_info;

CREATE TABLE IF NOT EXISTS public.du_rent_info (

  -- ── Primary key ─────────────────────────────────────────
  id                    BIGSERIAL PRIMARY KEY,

  -- ── Data provenance ─────────────────────────────────────
  -- Tracks whether the row came from an Excel upload or the DLD API
  source                VARCHAR(10)   NOT NULL CHECK (source IN ('Excel', 'API')),
  -- File name or API batch identifier for traceability
  source_ref            VARCHAR(255),
  -- Month/year the file covers, e.g. '2026-04'
  data_period           VARCHAR(7),

  -- ── Core DLD contract fields ─────────────────────────────
  registration_date     TIMESTAMPTZ,          -- REGISTRATION_DATE
  start_date            TIMESTAMPTZ,          -- START_DATE
  end_date              TIMESTAMPTZ,          -- END_DATE

  -- Contract version: 'New' | 'Renewed'
  version_en            VARCHAR(20),          -- VERSION_EN

  -- ── Location ────────────────────────────────────────────
  area_en               VARCHAR(255),         -- AREA_EN  (community/area name)
  master_project_en     VARCHAR(255),         -- MASTER_PROJECT_EN
  project_en            VARCHAR(255),         -- PROJECT_EN

  -- Proximity references (nullable — many rows are blank in DLD data)
  nearest_metro_en      VARCHAR(255),         -- NEAREST_METRO_EN
  nearest_mall_en       VARCHAR(255),         -- NEAREST_MALL_EN
  nearest_landmark_en   VARCHAR(255),         -- NEAREST_LANDMARK_EN

  -- ── Property details ────────────────────────────────────
  prop_type_en          VARCHAR(50),          -- PROP_TYPE_EN  e.g. Unit, Villa, Building, Land
  prop_sub_type_en      VARCHAR(100),         -- PROP_SUB_TYPE_EN  e.g. Flat, Office, Studio
  usage_en              VARCHAR(100),         -- USAGE_EN  e.g. Residential, Commercial
  is_free_hold_en       VARCHAR(20),          -- IS_FREE_HOLD_EN  'Free Hold' | 'Non Free Hold'

  actual_area           NUMERIC(18, 4),       -- ACTUAL_AREA  (sqft)
  rooms                 SMALLINT,             -- ROOMS  (bedrooms; NULL when not applicable)
  parking               SMALLINT,             -- PARKING  (spaces; NULL when not provided)
  total_properties      INTEGER,              -- TOTAL_PROPERTIES

  -- ── Financial fields ────────────────────────────────────
  -- Both in AED; can differ for multi-payment contracts
  contract_amount       NUMERIC(18, 2),       -- CONTRACT_AMOUNT (total contract value AED)
  annual_amount         NUMERIC(18, 2),       -- ANNUAL_AMOUNT   (annualised rent AED)

  -- ── Computed / derived fields (optional, can populate via trigger) ──
  -- Gross yield helper — requires purchase price which is in transactions table
  -- Kept here as nullable so the analytics layer can join and populate
  annual_amount_usd     NUMERIC(18, 2)        GENERATED ALWAYS AS (annual_amount / 3.6725) STORED,
  contract_duration_days INTEGER             GENERATED ALWAYS AS (
                            EXTRACT(DAY FROM (end_date - start_date))::INTEGER
                          ) STORED,

  -- ── Audit ───────────────────────────────────────────────
  created_at            TIMESTAMPTZ           NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ           NOT NULL DEFAULT NOW()

);

-- ============================================================
-- Indexes — tuned for PropWise query patterns
-- ============================================================

-- Most common filter: area / community
CREATE INDEX IF NOT EXISTS idx_du_rent_area
  ON public.du_rent_info (area_en);

-- Date-range queries (weekly data refresh, monthly dashboards)
CREATE INDEX IF NOT EXISTS idx_du_rent_registration_date
  ON public.du_rent_info (registration_date DESC);

CREATE INDEX IF NOT EXISTS idx_du_rent_start_date
  ON public.du_rent_info (start_date DESC);

-- Property type filters
CREATE INDEX IF NOT EXISTS idx_du_rent_prop_type
  ON public.du_rent_info (prop_type_en, prop_sub_type_en);

-- Usage filter (Residential vs Commercial)
CREATE INDEX IF NOT EXISTS idx_du_rent_usage
  ON public.du_rent_info (usage_en);

-- Source traceability
CREATE INDEX IF NOT EXISTS idx_du_rent_source
  ON public.du_rent_info (source, data_period);

-- Composite for heatmap query: area + date + usage
CREATE INDEX IF NOT EXISTS idx_du_rent_heatmap
  ON public.du_rent_info (area_en, usage_en, registration_date DESC);

-- ============================================================
-- Auto-update updated_at on row change
-- ============================================================

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_du_rent_updated_at ON public.du_rent_info;
CREATE TRIGGER trg_du_rent_updated_at
  BEFORE UPDATE ON public.du_rent_info
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ============================================================
-- Row Level Security (RLS) — Supabase standard pattern
-- ============================================================

ALTER TABLE public.du_rent_info ENABLE ROW LEVEL SECURITY;

-- Authenticated users can read all rent data (your subscribers)
CREATE POLICY "Authenticated users can read du_rent_info"
  ON public.du_rent_info
  FOR SELECT
  TO authenticated
  USING (true);

-- Only service_role (your backend/cron) can insert / update / delete
CREATE POLICY "Service role can manage du_rent_info"
  ON public.du_rent_info
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- ============================================================
-- Comments — self-documenting for future teammates
-- ============================================================

COMMENT ON TABLE  public.du_rent_info IS
  'Dubai rental contracts from DLD open data. Naming: du=Dubai, rent=business domain. Source column tracks Excel upload vs API ingestion.';

COMMENT ON COLUMN public.du_rent_info.source IS
  'Excel = imported from DLD monthly CSV/Excel file. API = ingested via DLD live API (Year 2+).';
COMMENT ON COLUMN public.du_rent_info.source_ref IS
  'File name (e.g. rents-2026-04.csv) or API batch ID for traceability.';
COMMENT ON COLUMN public.du_rent_info.data_period IS
  'YYYY-MM period the export covers, e.g. 2026-04. Set at import time.';
COMMENT ON COLUMN public.du_rent_info.contract_amount IS
  'Total contract value in AED. May differ from annual_amount for multi-year or multi-payment contracts.';
COMMENT ON COLUMN public.du_rent_info.annual_amount IS
  'Annualised rent in AED. Use this for yield calculations.';
COMMENT ON COLUMN public.du_rent_info.annual_amount_usd IS
  'Annual amount auto-converted to USD at fixed AED/USD 3.6725 peg.';
COMMENT ON COLUMN public.du_rent_info.rooms IS
  'Number of bedrooms. NULL for commercial properties and land.';
COMMENT ON COLUMN public.du_rent_info.actual_area IS
  'Property area in square feet as filed with DLD.';
