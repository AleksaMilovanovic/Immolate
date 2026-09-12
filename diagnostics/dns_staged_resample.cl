// Thin alias kept so existing benchmark configs and the diag-dns profile keep
// working: the depth-major staged resample IS deep_negative_shops now, so this
// is the shipped filter at its default chunk. Was a full 487-line copy, which
// had to stay bit-identical to the real filter by hand.
#include "filters/deep_negative_shops.cl"
