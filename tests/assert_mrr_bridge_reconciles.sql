-- Singular test: every month, opening + new - churned must equal closing MRR.
-- If this fails, a subscription is being double counted or dropped somewhere.
select
    month_start,
    opening_mrr_eur,
    new_mrr_eur,
    churned_mrr_eur,
    closing_mrr_eur
from {{ ref('fct_mrr_monthly') }}
where abs(opening_mrr_eur + new_mrr_eur - churned_mrr_eur - closing_mrr_eur) > 0.01
