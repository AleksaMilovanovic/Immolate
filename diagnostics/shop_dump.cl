// Diagnostic: the ante voucher and the first SD_SLOTS shop cards of antes 1-3,
// as the game would show them on a fresh run with a completed profile (upgrade
// vouchers, Planet X / Ceres / Eris and Cavendish locked; everything else
// unlocked). Six slots is the opening shop plus two rerolls. Run on one seed:
//   immolate -f shop_dump -s SEED -n 1 -g 1
// Used to compare GPU, CPU and the game draw by draw.
#include "lib/immolate.cl"
#ifndef SD_SLOTS
#define SD_SLOTS 6
#endif
long filter(instance* inst) {
    init_locks(inst, 1, false, true);
    // fresh_run also locks profile-unlock jokers; a completed profile has them.
    i_unlock(inst, Stone_Joker); i_unlock(inst, Steel_Joker); i_unlock(inst, Glass_Joker);
    i_unlock(inst, Golden_Ticket); i_unlock(inst, Lucky_Cat);
    for (int ante = 1; ante <= 3; ante++) {
        init_unlocks(inst, ante, false);
        printf("ante %d voucher: ", ante); print_item(next_voucher(inst, ante)); printf("\n");
        for (int i = 0; i < SD_SLOTS; i++) {
            shopitem s = next_shop_item(inst, ante);
            printf("ante %d slot %d: ", ante, i + 1);
            print_item(s.value);
            if (s.type == ItemType_Joker) { printf(" ["); print_item(s.joker.edition); printf("]"); }
            printf("\n");
        }
    }
    return 1;
}
