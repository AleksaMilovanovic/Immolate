// Shared tail of the diag_count_<filter>.cl wrappers. Each wrapper defines
// DIAG_COUNTERS, includes the real filter with its `filter` renamed to
// diag_real_filter, then includes this and defines a filter() that runs the
// real one and returns two of the counters packed into the score:
// high 32 bits = first of the pair, low 32 bits = second. Select the pair with
// --build_opts -DDIAG_PAIR=<0..4> and read the values back with --scores_to.
#ifndef DIAG_PAIR
#define DIAG_PAIR 0
#endif
inline long diag_pack(instance* inst) {
    ulong a, b;
#if DIAG_PAIR == 0
    a = inst->diag.nodeResolve; b = inst->diag.nodeCreate;
#elif DIAG_PAIR == 1
    a = inst->diag.lastHit;     b = inst->diag.scanCmp;
#elif DIAG_PAIR == 2
    a = inst->diag.advance;     b = inst->diag.reseed;
#elif DIAG_PAIR == 3
    a = inst->diag.draw;        b = inst->diag.phName;
#else
    a = inst->diag.phSeed;      b = inst->diag.phInit;
#endif
    return (long)((a << 32) | (b & 0xFFFFFFFFUL));
}
