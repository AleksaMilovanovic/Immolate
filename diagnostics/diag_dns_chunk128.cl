// DIAGNOSTIC FIXTURE - deep_negative_shops with the staging chunk forced back
// to 128, the value shipped before the chunk sweep. Scores are CORRECT and
// bit-identical. Kept as the regression control for the 512 change.
#define DNS_CHUNK 128
#include "filters/deep_negative_shops.cl"
