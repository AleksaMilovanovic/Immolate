// Cost-attribution wrapper, not a filter: runs negative_tags and returns its
// operation counters (see diag_count_common.cl). Use with --scores_to.
#define DIAG_COUNTERS
#define filter diag_real_filter
#include "filters/negative_tags.cl"
#undef filter
#include "diagnostics/diag_count_common.cl"
long filter(instance* inst, long cutoff) { diag_real_filter(inst, 0); return diag_pack(inst); }
