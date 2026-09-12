// DIAGNOSTIC FIXTURE - PRODUCES DELIBERATELY WRONG SCORES
// Removes: the VOUCHER stream and its resamples - one next_voucher() per ante
// 1..38, each resampling while it lands on a locked upgrade voucher. MEASURED
// at 114.6 draws/seed (min 79, max 183), NOT the <=76 the planning table
// assumed: 16 of the 32 VOUCHERS start locked, so the resample chain roughly
// doubles the stream. Still only 0.22% of all draws.
// Replaced by the constant Hone, which is not in DNS_BOUGHT_VOUCHERS, so
// nothing activates.
// CAVEAT, stated because this is the one ablation in the family that is NOT
// work-volume neutral: it also removes early-Overstock frame growth. Measured
// shop card-type draws are 18,624/seed with vouchers and exactly 17,910
// without (that is the no-Overstock floor), so ablating vouchers also removes
// 3.8% of the downstream shop work. Read this fixture as an UPPER BOUND on the
// voucher share, and subtract a ~3.8%-of-shop-cost correction before believing
// the number.
// Measures: the voucher stream's share of total runtime.
// Implementation: COPY, not a #define hook on the shipped filter - it goes
// through filters/dns_sub_core.cl, an instrumented copy of
// deep_negative_shops.cl that must be re-synced BY HAND when that file changes.
#define DNS_SUB_VOUCHERS 1
#include "filters/dns_sub_core.cl"
