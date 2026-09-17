// Cost-attribution wrapper, not a filter: runs deep_negative_shops and returns its
// operation counters (see diag_count_common.cl). Use with --scores_to.
#define DIAG_COUNTERS
#define filter diag_real_filter
#include "filters/deep_negative_shops.cl"
#undef filter
#include "diagnostics/diag_count_common.cl"
long filter(instance* inst) { diag_real_filter(inst); return diag_pack(inst); }
