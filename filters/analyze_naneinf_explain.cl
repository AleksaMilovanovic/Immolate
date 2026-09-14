// analyze_naneinf_negatives with the strategy printout turned on. Same score,
// same search; it just says what the winning line does. One seed at a time:
//   immolate -f analyze_naneinf_explain -s SEED -n 1 -g 1 -c 0
// It runs the whole search TWICE -- once to find the best line, once to price
// every alternative against it -- so it costs about double the plain filter on
// the same seed, and the plain filter's own cost grows with the branch-point
// count. A seed with 12 branch points is ~40s of single-threaded work, so ~80s
// here. Add -D ANN_NO_ALTS to skip the second pass and print only the winning
// line; that halves it and loses just the "alternatives" column.
//
// --group_per_seed does NOT help: it would run the printout once per lane. The
// filter rejects that combination at compile time.
//
// Do not point it at a range.
#define ANN_EXPLAIN
#include "filters/analyze_naneinf_negatives.cl"
