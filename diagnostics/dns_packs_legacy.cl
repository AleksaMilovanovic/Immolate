// A/B BASELINE - deep_negative_shops with the original one-draw-at-a-time pack
// loop instead of the phased one. Scores are CORRECT and bit-identical to the
// shipped filter; only the order in which independent RNG nodes are visited
// differs, so any measured gap is scheduling, not work.
//
// Pair with the shipped filter to measure the pack restructure:
//   python tests/run.py --profile diag-packs --scale rtx5080
#define DNS_PACKS_LEGACY 1
#include "filters/deep_negative_shops.cl"
