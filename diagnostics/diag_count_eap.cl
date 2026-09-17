// Cost-attribution wrapper, not a filter. See diag_count_common.cl.
#define DIAG_COUNTERS
#define filter diag_real_filter
#include "filters/early_ante_perkeo.cl"
#undef filter
#include "diagnostics/diag_count_common.cl"
long filter(instance* inst) { diag_real_filter(inst); return diag_pack(inst); }
