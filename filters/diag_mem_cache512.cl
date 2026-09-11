// DIAGNOSTIC FIXTURE - not a real filter, never wire into correctness goldens.
// deep_negative_shops with CACHE_SIZE forced to 512.
#define DNS_CACHE_SIZE_OVERRIDE 512
#include "filters/deep_negative_shops.cl"
