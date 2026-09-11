// Thin alias: the shipped filter with the staging chunk forced back to 32, the
// value it used before the depth-major resample change. Kept as the A/B control
// for how much of the win comes from chunk size versus from depth-major order.
#define DNS_CHUNK 32
#include "filters/deep_negative_shops.cl"
