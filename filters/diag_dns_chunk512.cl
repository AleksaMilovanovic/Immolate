// DIAGNOSTIC FIXTURE - deep_negative_shops with the staging chunk set to 512.
// Scores are CORRECT and bit-identical to the shipped filter: chunk size only
// changes how many shop joker slots are staged before the identity streams are
// drawn depth-major, never which draws happen or in what order within a node.
#define DNS_CHUNK 512
#include "filters/deep_negative_shops.cl"
