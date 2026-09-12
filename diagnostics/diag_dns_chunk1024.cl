// DIAGNOSTIC FIXTURE - deep_negative_shops with the staging chunk set to 1024.
// Scores are CORRECT and bit-identical to the shipped filter.
//
// PREDICTION: the largest ante (38) has 924 shop cards and ~660 joker cards, so
// any chunk >= 1024 is always exactly one chunk per ante. 1024 and 2048 must
// therefore measure IDENTICALLY; if they do not, something other than chunking
// is moving and the sweep is not measuring what it claims.
//
// COUNTER-PREDICTION: the staging masks are DNS_CHUNK bits wide, so at 1024
// each is 16 ulongs = 32 registers, and ~5 are live at once = ~160 registers --
// past the 128-register cap the NVIDIA build now applies, so this should SPILL
// and may regress. If 1024 is slower than 512, register pressure is the reason,
// not chunking, and the fix is to size the pool masks independently of the
// chunk (see docs/diagnostics.md).
#define DNS_CHUNK 1024
#include "filters/deep_negative_shops.cl"
