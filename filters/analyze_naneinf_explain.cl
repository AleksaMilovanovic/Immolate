// analyze_naneinf_negatives with the strategy printout turned on. Same score,
// same search; it just says what the winning line does. One seed at a time:
//   immolate -f analyze_naneinf_explain -s SEED -n 1 -g 1 -c 0
// It runs the whole search twice (once to find the best line, once to price
// every alternative against it), so do not point it at a range.
#define ANN_EXPLAIN
#include "filters/analyze_naneinf_negatives.cl"
