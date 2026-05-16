-- Average rent by area (feeds the heatmap)
SELECT
  area_en,
  COUNT(*)                        AS contracts,
  ROUND(AVG(annual_amount))       AS avg_annual_aed,
  ROUND(AVG(actual_area), 1)      AS avg_sqft
FROM public.du_rent_info
WHERE usage_en = 'Residential'
  AND prop_sub_type_en = 'Flat'
  AND annual_amount > 0
GROUP BY area_en
ORDER BY avg_annual_aed DESC;