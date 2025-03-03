#ifdef TEST_MAIN_3_TO_4

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern int* xua_4_to_3(int *output, int *input, int N);
extern int* xua_3_to_4(int *output, int *input, int N);

int main(void) {
    char x[18] = {1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18};
    int *xx = x;
    int out[6];
    char xo[18];
    int *xxo = xo;
    for(int i = 1; i <= 6; i++) {
        memset(out, 0, sizeof(out));
        xua_3_to_4(out, xx, i);
        memset(xxo, 0, 18);
        xua_4_to_3(xxo, out, i);
        for(int i = 0; i < 6; i++) {
            printf("%08x ", out[i]);
        }
        printf("\n");
        for(int i = 0; i < 18; i++) {
            printf("%02x ", xo[i]);
        }
        printf("\n");
    }
}

#endif
