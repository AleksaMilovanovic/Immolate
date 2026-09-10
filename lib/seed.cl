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
    long rank = 0;
    for (int i = 0; i < s->len; i++) {
        rank = rank * NUM_CHARS + (long)s->data[i] + 1;
    }
    return rank;
}
// Inverse of s_tell.
seed s_from_rank(long rank) {
    seed s;
    s.data = 0;
    s.len = 0;
    while (rank > 0 && s.len < 8) {
        long r1 = rank - 1;
        s.data[s.len] = r1 % NUM_CHARS; // least significant digit first, reversed below
        rank = r1 / NUM_CHARS;
        s.len++;
    }
    for (int lo = 0, hi = s.len - 1; lo < hi; lo++, hi--) {
        ulong t = s.data[lo];
        s.data[lo] = s.data[hi];
        s.data[hi] = t;
    }
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