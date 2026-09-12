// DIAGNOSTIC FIXTURE - not a real filter, never wire into correctness goldens.
// deep_negative_shops with 2 KB of unused private memory added to the kernel
// frame. Draws, ALU and cache traffic are byte-identical to diag_mem_ballast0;
// only the per-work-item footprint differs. Scores stay bit-identical, so a
// score difference against the baseline means the ballast was miscompiled.
#define DIAG_BALLAST_KB 2
#include "filters/deep_negative_shops.cl"
