// analyze_naneinf_negatives with the strategy printout turned on. Same search,
// same score; it just says what the winning line does. One seed at a time:
//   immolate -f analyze_naneinf_explain -s SEED -n 1 -g 1 -c 0
// It runs the whole search TWICE -- once to find the best line, once to price
// every alternative against it -- so it costs about double the plain filter on
// the same seed, and the plain filter's own cost grows with the branch-point
// count. Add -D ANN_NO_ALTS to skip the second pass and print only the winning
// line; that halves it and loses just the "alternatives" column.
//
// Dominance pruning is OFF here, unlike the plain filter where it is on by
// default. Pruning is a bet that pays off across a pool -- it keeps the RANKING
// while letting an individual mid-pool seed's score slip -- and explaining one
// named seed is exactly the case the bet is not made for. It also makes the
// alternatives column traversal-dependent: each lane of a --group_per_seed run
// carries its own frontier, so lanes prune differently and price the
// alternatives differently, even though they agree on the winner. Pass
// -D ANN_DOMINANCE to opt back in if a seed is too deep to explain otherwise,
// and read the alternatives as approximate when you do.
#ifndef ANN_DOMINANCE
#define ANN_NO_DOMINANCE
#endif

// --group_per_seed DOES work here, and on a deep seed it is the difference
// between minutes and seconds, but it needs the seed in a file rather than -s:
//   echo SEED > one.txt
//   immolate -f analyze_naneinf_explain --from one.txt -n 1 -g 1 -c 0 --group_per_seed
// The lanes split the tree, elect the one that actually held the winner, and
// only that lane prints -- so the output is the same single strategy, byte for
// byte, as the one-lane run. (It used to be rejected at compile time, because
// without the election every lane printed its own share's best line.)
//
// Do not point it at a range.
#define ANN_EXPLAIN
#include "filters/analyze_naneinf_negatives.cl"
