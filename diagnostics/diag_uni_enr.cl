// Divergence probe, not a filter. See diag_uni_erratic.cl.
#ifndef UNI_MASK
#define UNI_MASK 0
#endif
#define filter diag_real_filter
#include "filters/early_negative_rares.cl"
#undef filter
long filter(instance* inst) {
    long r = s_tell(&inst->seed);
    seed s = s_from_rank(r & ~(long)(UNI_MASK));
    i_init(inst, s);
    return diag_real_filter(inst);
}
