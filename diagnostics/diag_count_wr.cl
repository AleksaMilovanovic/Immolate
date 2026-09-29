// Cost-attribution wrapper, not a filter: runs wr_filter and returns its
// operation counters (see diag_count_common.cl). Use with --scores_to.
#define DIAG_COUNTERS
#define filter diag_real_filter
#include "filters/wr_filter.cl"
#undef filter
#include "diagnostics/diag_count_common.cl"
long filter(instance* inst) { diag_real_filter(inst); return diag_pack(inst); }
