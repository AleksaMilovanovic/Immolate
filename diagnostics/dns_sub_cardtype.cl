// DIAGNOSTIC FIXTURE - PRODUCES DELIBERATELY WRONG SCORES
// Removes: the shop CARD-TYPE poll (measured 18,624/seed, 35.6% of all draws) - the
// per-shop-card draw that decides Joker/Tarot/Planet. jokerCards becomes the
// exact expectation cards*20/28, so every downstream stream runs the same
// number of times; only this stream's draws vanish.
// Measures: the card-type stream's share of total runtime.
// Implementation: COPY, not a #define hook on the shipped filter - it goes
// through filters/dns_sub_core.cl, an instrumented copy of
// deep_negative_shops.cl that must be re-synced BY HAND when that file changes.
#define DNS_SUB_CARDTYPE 1
#include "diagnostics/dns_sub_core.cl"
