// RNG Cache
typedef enum RandomType {
    R_Joker_Common,
    R_Joker_Uncommon,
    R_Joker_Rare,
    R_Joker_Legendary,
    R_Joker_Rarity,
    R_Joker_Edition,
    R_Misprint,
    R_Standard_Has_Enhancement,
    R_Enhancement,
    R_Card,
    R_Standard_Edition,
    R_Standard_Has_Seal,
    R_Standard_Seal,
    R_Shop_Pack,
    R_Tarot,
    R_Spectral,
    R_Tags,
    R_Shuffle_New_Round,
    R_Card_Type,
    R_Planet,
    R_Lucky_Mult,
    R_Lucky_Money,
    R_Sigil,
    R_Ouija,
    R_Wheel_of_Fortune,
    R_Gros_Michel,
    R_Cavendish,
    R_Voucher,
    R_Voucher_Tag,
    R_Orbital_Tag,
    R_Soul,
    R_Erratic,
    R_Eternal,
    R_Perishable,
    R_Eternal_Perishable,
    R_Eternal_Perishable_Pack,
    R_Rental,
    R_Rental_Pack,
    R_Boss,
    R_END
} rtype;

typedef enum RNGSource {
    S_Shop,
    S_Emperor,
    S_High_Priestess,
    S_Judgement,
    S_Wraith,
    S_Arcana,
    S_Celestial,
    S_Spectral,
    S_Standard,
    S_Buffoon,
    S_Vagabond,
    S_Superposition,
    S_Seance,
    S_Sixth_Sense,
    S_Top_Up,
    S_Rare_Tag,
    S_Uncommon_Tag,
    S_Blue_Seal,
    S_Purple_Seal,
    S_8_Ball,
    S_Soul,
    S_Riff_Raff,
    S_Cartomancer,
    S_Null,
    SOURCE_END
} rsrc;

typedef enum NodeType {
    N_Type,
    N_Source,
    N_Ante,
    N_Resample
} ntype;

// Node-name components. Each is a pointer into __constant memory plus a
// length; the RNG path streams the characters straight into the hash and never
// builds a string. (Earlier versions returned a 260-byte `text` by value from
// each of these, and get_node_child held four of them: 1,040 bytes of stack
// per inlined call site, which drove the kernel to 255 registers and forced
// random() out of line on NVIDIA.)
__constant char* type_cstr(int x, int* len) {
    switch(x) {
        case R_Joker_Common:             *len = 6;  return "Joker1";
        case R_Joker_Uncommon:           *len = 6;  return "Joker2";
        case R_Joker_Rare:               *len = 6;  return "Joker3";
        case R_Joker_Legendary:          *len = 6;  return "Joker4";
        case R_Joker_Rarity:             *len = 6;  return "rarity";
        case R_Joker_Edition:            *len = 3;  return "edi";
        case R_Misprint:                 *len = 8;  return "misprint";
        case R_Standard_Has_Enhancement: *len = 6;  return "stdset";
        case R_Enhancement:              *len = 8;  return "Enhanced";
        case R_Card:                     *len = 5;  return "front";
        case R_Standard_Edition:         *len = 16; return "standard_edition";
        case R_Standard_Has_Seal:        *len = 7;  return "stdseal";
        case R_Standard_Seal:            *len = 11; return "stdsealtype";
        case R_Shop_Pack:                *len = 9;  return "shop_pack";
        case R_Tarot:                    *len = 5;  return "Tarot";
        case R_Spectral:                 *len = 8;  return "Spectral";
        case R_Tags:                     *len = 3;  return "Tag";
        case R_Shuffle_New_Round:        *len = 2;  return "nr";
        case R_Card_Type:                *len = 3;  return "cdt";
        case R_Planet:                   *len = 6;  return "Planet";
        case R_Lucky_Mult:               *len = 10; return "lucky_mult";
        case R_Lucky_Money:              *len = 11; return "lucky_money";
        case R_Sigil:                    *len = 5;  return "sigil";
        case R_Ouija:                    *len = 5;  return "ouija";
        case R_Wheel_of_Fortune:         *len = 16; return "wheel_of_fortune";
        case R_Gros_Michel:              *len = 11; return "gros_michel";
        case R_Cavendish:                *len = 9;  return "cavendish";
        case R_Voucher:                  *len = 7;  return "Voucher";
        case R_Voucher_Tag:              *len = 15; return "Voucher_fromtag";
        case R_Orbital_Tag:              *len = 7;  return "orbital";
        case R_Soul:                     *len = 5;  return "soul_";
        case R_Erratic:                  *len = 7;  return "erratic";
        case R_Eternal:                  *len = 24; return "stake_shop_joker_eternal";
        case R_Perishable:               *len = 4;  return "ssjp";
        case R_Rental:                   *len = 4;  return "ssjr";
        case R_Eternal_Perishable:       *len = 9;  return "etperpoll";
        case R_Rental_Pack:              *len = 8;  return "packssjr";
        case R_Eternal_Perishable_Pack:  *len = 9;  return "packetper";
        case R_Boss:                     *len = 4;  return "boss";
        default:                         *len = 0;  return "";
    }
}
__constant char* source_cstr(int x, int* len) {
    switch(x) {
        case S_Shop:           *len = 3; return "sho";
        case S_Emperor:        *len = 3; return "emp";
        case S_High_Priestess: *len = 3; return "pri";
        case S_Judgement:      *len = 3; return "jud";
        case S_Wraith:         *len = 3; return "wra";
        case S_Arcana:         *len = 3; return "ar1";
        case S_Celestial:      *len = 3; return "pl1";
        case S_Spectral:       *len = 3; return "spe";
        case S_Standard:       *len = 3; return "sta";
        case S_Buffoon:        *len = 3; return "buf";
        case S_Vagabond:       *len = 3; return "vag";
        case S_Superposition:  *len = 3; return "sup";
        case S_8_Ball:         *len = 3; return "8ba";
        case S_Seance:         *len = 3; return "sea";
        case S_Sixth_Sense:    *len = 5; return "sixth";
        case S_Top_Up:         *len = 3; return "top";
        case S_Rare_Tag:       *len = 3; return "rta";
        case S_Uncommon_Tag:   *len = 3; return "uta";
        case S_Blue_Seal:      *len = 5; return "blusl";
        case S_Purple_Seal:    *len = 3; return "8ba";
        case S_Soul:           *len = 3; return "sou";
        case S_Riff_Raff:      *len = 3; return "rif";
        case S_Cartomancer:    *len = 3; return "car";
        default:               *len = 0; return "";
    }
}
// Decimal digit count, matching int_to_str's length rule (0 -> 1 digit).
inline int dec_len(int x) {
    int digits = 1;
    while (x / 10 > 0) {
        digits++;
        x /= 10;
    }
    return digits;
}
// Length in characters of one node-name component.
int node_part_len(ntype nt, int x) {
    int len = 0;
    switch (nt) {
        case N_Type:     type_cstr(x, &len); return len;
        case N_Source:   source_cstr(x, &len); return len;
        case N_Ante:     return dec_len(x);
        case N_Resample: return x == 0 ? 0 : 9 + dec_len(x + 1);
    }
    return 0;
}
// Feed the decimal digits of x into the hash, last digit first, decrementing
// *pos per character. Emits exactly the characters int_to_str would.
inline double ph_decimal_rev(double h, int* pos, int x) {
    do {
        h = ph_step(h, '0' + x % 10, (*pos)--);
        x /= 10;
    } while (x > 0);
    return h;
}
inline double ph_cstr_rev(double h, int* pos, __constant char* s, int len) {
    for (int i = len - 1; i >= 0; i--) {
        h = ph_step(h, s[i], (*pos)--);
    }
    return h;
}
// Feed one node-name component into the hash, last character first.
double ph_node_part_rev(double h, int* pos, ntype nt, int x) {
    int len;
    switch (nt) {
        case N_Type:   return ph_cstr_rev(h, pos, type_cstr(x, &len), len);
        case N_Source: return ph_cstr_rev(h, pos, source_cstr(x, &len), len);
        case N_Ante:   return ph_decimal_rev(h, pos, x);
        case N_Resample:
            if (x == 0) return h;
            // "_resample" followed by (x+1): the digits come first when reversed.
            h = ph_decimal_rev(h, pos, x + 1);
            return ph_cstr_rev(h, pos, "_resample", 9);
    }
    return h;
}

#ifndef CACHE_SIZE
#define CACHE_SIZE 64
#endif

// A cache node is identified by up to 4 (nodeType, nodeValue) pairs packed into
// a single 64-bit key: 16 bits per slot, slot k at bits 16k..16k+15, holding
// ((nodeType & 3) << 14) | (nodeValue & 0x3FFF). Slots past the node's depth are
// 0xFFFF, which no real slot can produce because every nodeValue in use is well
// below 0x3FFF (rtype < 40, rsrc < 24, antes are small, resample counters are
// small), so the key encodes the depth as well as the contents.
#define NODE_SLOT_EMPTY 0xFFFFUL
inline ulong node_key(ntype nts[], int ids[], int num) {
    ulong key = 0;
    for (int i = 0; i < 4; i++) {
        ulong slot = (i < num)
            ? ((((ulong)nts[i] & 3UL) << 14) | ((ulong)ids[i] & 0x3FFFUL))
            : NODE_SLOT_EMPTY;
        key |= slot << (16 * i);
    }
    return key;
}

typedef struct RNGInfo {
    ulong key;
    double rngState;
} rnginfo;

typedef struct Cache {
    rnginfo nodes[CACHE_SIZE];
    bool generatedFirstPack;
    bool reportedOverflow;
    int nextFreeNode;
} cache;

int init_node(cache* c, ulong key) {
    if (c->nextFreeNode >= CACHE_SIZE) {
        // Previously this wrote past nodes[] silently. Warn once per work-item
        // and reuse the last slot instead; results for this seed will be wrong,
        // but nothing is corrupted.
        if (!c->reportedOverflow) {
            c->reportedOverflow = true;
            printf("Immolate: RNG node cache overflow, CACHE_SIZE=%d is too small for this filter\n", CACHE_SIZE);
        }
        c->nodes[CACHE_SIZE-1].key = key;
        return CACHE_SIZE-1;
    }
    c->nodes[c->nextFreeNode].key = key;
    c->nextFreeNode++;
    return c->nextFreeNode-1;
};