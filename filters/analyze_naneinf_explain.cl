// analyze_naneinf_negatives with the strategy printout turned on. Same search,
// same score; it just says what the winning line does. One seed at a time:
//   immolate -f analyze_naneinf_explain -s SEED -n 1
//
// Defaults are the fast ones, the same as the plain filter: dominance pruning
// ON, the alternatives pass OFF, and one work-group per seed (the host turns
// --group_per_seed on for every ANN filter; --no_group_per_seed turns it off).
// So the score printed is the plain filter's score for that seed.
//
// Build options (pass with --build_opts "-D NAME" or "-D NAME=VALUE"):
// @opt ANN_ALTS  also price every alternative at each branch point (a second full search, ~2x)
// @opt ANN_NO_DOMINANCE  exhaustive search: the exact score for this seed, much slower on deep seeds
//
// ANN_ALTS runs the whole search TWICE -- once to find the best line, once to
// price every alternative against it -- so it costs about double. With pruning
// on, the alternatives column is traversal-dependent: each lane carries its own
// frontier, so lanes prune differently and price the alternatives differently,
// even though they agree on the winner. Read it as approximate unless
// ANN_NO_DOMINANCE is set too.
//
// Pruning is a bet that pays off across a pool -- it keeps the RANKING while
// letting an individual mid-pool seed's score slip -- so for one named seed's
// exact score, pass ANN_NO_DOMINANCE (see the DOMINANCE PRUNING note in
// analyze_naneinf_negatives.cl). Expect hours, not minutes, on a seed with
// more than a dozen branch points; diagnostics/naneinf_branch_tree.cl says how
// many leaves a seed has before you commit to it.
//
// The lanes split the tree, elect the one that actually held the winner, and
// only that lane prints -- so the output is the same single strategy as a
// one-lane run.
//
// Do not point it at a range.
#ifndef ANN_ALTS
#define ANN_NO_ALTS
#endif
#define ANN_EXPLAIN
#include "filters/analyze_naneinf_negatives.cl"
