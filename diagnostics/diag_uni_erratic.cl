// Divergence probe, not a filter: runs erratic_flush_five on a seed whose rank is
// masked with ~UNI_MASK, so with -DUNI_MASK=31 every lane of a warp gets the
// same seed (no intra-warp divergence), with -DUNI_MASK=0 each lane keeps its
// own seed (control, paying the same extra s_tell/i_init), and with a huge
// mask the whole launch shares one seed. Start the range on a rank that is a
// multiple of 32 so warps do not straddle a mask boundary.
#ifndef UNI_MASK
#define UNI_MASK 0
#endif
#define filter diag_real_filter
#include "filters/erratic_flush_five.cl"
#undef filter
inline void diag_uni_reseed(instance* inst) {
    long r = s_tell(&inst->seed);
    seed s = s_from_rank(r & ~(long)(UNI_MASK));
    i_init(inst, s);
}
long filter(instance* inst) { diag_uni_reseed(inst); return diag_real_filter(inst); }
