// Some important definitions
__constant char SEEDCHARS[] = "123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
#define NUM_CHARS 35

int s_char_num(char c){
    return c - (49 + (c>57)*7);
}

typedef struct Seed {
    ulong8 data;
    int len;
} seed;
seed s_new_empty() {
    seed seed;
    seed.data = 0; //fills with zeros
    seed.len = 0;
    return seed;
}
seed s_new(__constant char* str_seed, int seed_size) {
    seed seed;
    for (int i = 0; i < seed_size; i++) {
        for (char j = 0; j < NUM_CHARS; j++) {
            if (SEEDCHARS[j] == str_seed[i]) {
                seed.data[i] = j;
            }
        }
    }
    seed.len = seed_size;
    return seed;
}

seed s_new_c8(char8 str_seed) {
    seed seed;
    for (int i = 0; i < 8; i++) {
        if (str_seed[i] == '\0') {
            seed.len = i;
            return seed;
        }
        seed.data[i] = s_char_num(str_seed[i]);
    }
    seed.len = 8;
    return seed;
}

char s_char_at(seed* s, int c) {
    return SEEDCHARS[s->data[c]];
}
// Seeds are numbered in bijective base 35: rank 0 is the empty seed, ranks
// 1..35 are the one-character seeds "1".."Z", ranks 36..1260 the two-character
// seeds, and so on. This is the ordering the searcher walks.
long s_tell(seed* s) {
    // Constant vector indices with a predicate per digit, for the same reason
    // as s_from_rank below: s->data[i] with a loop index spills the vector.
    long rank = 0;
    const int len = s->len;
#define S_TELL_DIGIT(i) if (i < len) rank = rank * NUM_CHARS + (long)s->data[i] + 1;
    S_TELL_DIGIT(0) S_TELL_DIGIT(1) S_TELL_DIGIT(2) S_TELL_DIGIT(3)
    S_TELL_DIGIT(4) S_TELL_DIGIT(5) S_TELL_DIGIT(6) S_TELL_DIGIT(7)
#undef S_TELL_DIGIT
    return rank;
}
// Inverse of s_tell. The previous version wrote each digit through a dynamic
// index into the ulong8 (s.data[s.len] = ...) and then swapped pairs the same
// way; NVIDIA's compiler cannot keep a dynamically indexed vector in
// registers, so every digit stored the whole 64-byte vector to the stack and
// reloaded it, twice per digit. Measured at 0.83 ns per seed, more than the
// seed's own 8-character hash. Here the eight digits are peeled into scalars
// (least significant first) and placed with compile-time indices; the length
// is uniform across lanes in practice (every searched seed is 8 characters),
// so the switch is a uniform branch. Same digits, same ordering, same result.
seed s_from_rank(long rank) {
    seed s;
    s.data = 0;
    ulong d0 = 0, d1 = 0, d2 = 0, d3 = 0, d4 = 0, d5 = 0, d6 = 0, d7 = 0;
    int len = 0;
#define S_FROM_RANK_DIGIT(d) \
    if (rank > 0) { long r1 = rank - 1; d = (ulong)(r1 % NUM_CHARS); rank = r1 / NUM_CHARS; len++; }
    S_FROM_RANK_DIGIT(d0) S_FROM_RANK_DIGIT(d1) S_FROM_RANK_DIGIT(d2) S_FROM_RANK_DIGIT(d3)
    S_FROM_RANK_DIGIT(d4) S_FROM_RANK_DIGIT(d5) S_FROM_RANK_DIGIT(d6) S_FROM_RANK_DIGIT(d7)
#undef S_FROM_RANK_DIGIT
    // Most significant digit first, as s_tell reads them.
    switch (len) {
        case 8: s.data = (ulong8)(d7, d6, d5, d4, d3, d2, d1, d0); break;
        case 7: s.data = (ulong8)(d6, d5, d4, d3, d2, d1, d0, 0); break;
        case 6: s.data = (ulong8)(d5, d4, d3, d2, d1, d0, 0, 0); break;
        case 5: s.data = (ulong8)(d4, d3, d2, d1, d0, 0, 0, 0); break;
        case 4: s.data = (ulong8)(d3, d2, d1, d0, 0, 0, 0, 0); break;
        case 3: s.data = (ulong8)(d2, d1, d0, 0, 0, 0, 0, 0); break;
        case 2: s.data = (ulong8)(d1, d0, 0, 0, 0, 0, 0, 0); break;
        case 1: s.data = (ulong8)(d0, 0, 0, 0, 0, 0, 0, 0); break;
        default: break;
    }
    s.len = len;
    return s;
}
// pseudohash of the seed string alone, streamed: no 260-byte text on the stack.
double pseudohash_seed(seed* s) {
    double num = 1;
    for (int i = s->len - 1; i >= 0; i--) {
        num = ph_step(num, s_char_at(s, i), i + 1);
    }
    return num;
}
text s_to_string(seed* s) {
    text str;
    for (int i = 0; i < s->len; i++) {
        str.str[i]=s_char_at(s, i);
    }
    set_text_length(&str, s->len);
    return str;
}

void s_print(seed* s) {
    text s_str = s_to_string(s);
    printf("%s",s_str.str);
}
// Print "SEED (score)". NVIDIA's OpenCL printf treats %li / %ld as 32-bit: on
// an RTX 5080 the 12-digit score 721353209655 printed as -201296073, its low
// 32 bits. So the value is printed through 32-bit pieces (up to three 9-digit
// groups) instead, which is exact for every 64-bit long on every platform.
void s_print_score(seed* s, long score) {
    text s_str = s_to_string(s);
    char sign[2];
    sign[0] = score < 0 ? '-' : '\0';
    sign[1] = '\0';
    ulong mag = score < 0 ? (ulong)(-(score + 1)) + 1UL : (ulong)score; // no overflow at LONG_MIN
    uint hi = (uint)(mag / 1000000000000000000UL);
    uint mid = (uint)((mag / 1000000000UL) % 1000000000UL);
    uint lo = (uint)(mag % 1000000000UL);
    if (hi) printf("%s (%s%u%09u%09u)\n", s_str.str, sign, hi, mid, lo);
    else if (mid) printf("%s (%s%u%09u)\n", s_str.str, sign, mid, lo);
    else printf("%s (%s%u)\n", s_str.str, sign, lo);
}
void s_print_rank(seed* s, long rank) {
    s_print_score(s, rank);
}
void s_next(seed* s) {
    s->data[s->len-1] = (s->data[s->len-1]+1)%NUM_CHARS;
    int carry = s->data[s->len-1] == 0;
    for (int i = s->len - 2; (i >= 0 && carry); i--) {
        s->data[i] = (s->data[i]+carry)%NUM_CHARS;
        carry = carry & (s->data[i] == 0);
    }
    s->len += carry;
}
// Advance the seed by n positions in the bijective base-35 ordering.
// The previous digit-wise implementation failed to borrow when it had to
// grow the seed by a digit whose value came out as -1, and stored that -1 as
// a digit; s_to_string then read one byte before SEEDCHARS. With the default
// empty starting seed roughly one work-item in twelve started on such a
// corrupt seed and searched garbage for the whole run. Going through the rank
// is exact for every start seed and stride, and costs about the same: one
// multiply per digit in, one divide per digit out.
void s_skip(seed* s, long n) {
    *s = s_from_rank(s_tell(s) + n);
}