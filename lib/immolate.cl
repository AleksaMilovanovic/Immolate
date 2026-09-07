// Based on C++ program by 00001H and MathIsFun_
#pragma OPENCL EXTENSION cl_khr_fp64 : enable
// Balatro runs on LuaJIT, which does plain IEEE fp64 with no fused multiply-add.
// The pseudohash and randomseed chains are bit-sensitive, so any contraction
// changes which items a seed produces. NVIDIA's compiler fuses by default:
// on an RTX 5080 it turned randomseed's `d*pi; d+e` into one fma, and seed
// LP4K3AAQ then drew different shop cards than the game (verified in-game on
// seeds 123I and 11FC against the unfused values). Contraction stays off for
// every kernel source; the explicit fma() calls in util.cl are unaffected,
// they are deliberate and exact.
#pragma OPENCL FP_CONTRACT OFF
#ifndef GAME_VERSION
    #define VER1 1
    #define VER2 0
    #define VER3 1
    #define VER4 6 //1.0.1f
    #define GAME_VERSION
#endif
#include "lib/util.cl" // Contains utility functions
#include "lib/seed.cl" // Contains seed/seed list info
#include "lib/items.cl" // Contains item enums, lists, helper functions
#include "lib/debug.cl" // Debug printing functions
#include "lib/cache.cl" // Contains RNG Cache implementation
#include "lib/instance.cl" // Contains random instance implementation and core functions
#include "functions.cl" // Contains utility functions for searching seeds - what the user would interact with