// analyze_naneinf_negatives scoring only Negative ETERNAL Blueprint, Brainstorm,
// Baron and Mime. Same search and cola engine; see the ETERNAL ONLY note at the
// top of analyze_naneinf_negatives.cl. Assumes Black Stake or higher.
//   immolate -f analyze_naneinf_eternal --from pool.txt -c 100
// For the strategy behind one seed, the explain wrapper takes the same flag:
//   immolate -f analyze_naneinf_explain -s SEED -n 1 --build_opts "-D ANN_ETERNAL_ONLY"
#define ANN_ETERNAL_ONLY
#include "filters/analyze_naneinf_negatives.cl"
