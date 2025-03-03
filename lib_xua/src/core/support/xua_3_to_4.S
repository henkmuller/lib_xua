// Copyright 2025-2025 XMOS LIMITED.
// This Software is subject to the terms of the XMOS Public Licence: Version 1.
#if defined(__XS3A__)

#define FUNCTION_NAME xua_3_to_4
    // xua_3_to_4(int *output, int *input, int count)
    // r0: argument 1, output (word aligned)
    // r1: argument 2, input  (word aligned)
    // r2: argument 3, count  (number of 3-byte chunks to read, must be > 0)

#define NSTACKWORDS   2
    .globl FUNCTION_NAME
    .globl FUNCTION_NAME.nstackwords
    .globl FUNCTION_NAME.maxthreads
    .globl FUNCTION_NAME.maxtimers
    .globl FUNCTION_NAME.maxchanends
    .linkset FUNCTION_NAME.nstackwords, NSTACKWORDS
    .linkset FUNCTION_NAME.threads, 0
    .linkset FUNCTION_NAME.maxtimers, 0
    .linkset FUNCTION_NAME.chanends, 0

    .cc_top FUNCTION_NAME.func, FUNCTION_NAME
    .type FUNCTION_NAME, @function
    
    .text
    .issue_mode dual
    .align 16

FUNCTION_NAME:   
    { dualentsp NSTACKWORDS     ; ldc r3, 8     }
    std    r4, r5, sp[0]
    { ldw  r4, r1[0]            ; add r1, r1, 4 }
    { sub r2, r2, 1             ; nop           }
loop2:
    { ldw  r4, r1[0]            ; add r5, r4, 0 }
    { add  r1, r1, 4            ; sub r3, r3, 8 }
    lextract r11, r4, r5, r3, 24
    { shl  r11, r11, 8          ; nop           }
    { stw  r11, r0[0]           ; add r0, r0, 4 }
    { bf   r2, done2            ; sub r2, r2, 1 }
    { bt   r3, loop2            ; nop           }
    ldc r3, 24
    lextract r11, r4, r5, r3, 24
    { shl  r11, r11, 8          ; nop           }
    { stw  r11, r0[0]           ; add r0, r0, 4 }
    { bt   r2, loop2            ; sub r2, r2, 1 }
done2:
    ldd r4, r5, sp[0]
    retsp NSTACKWORDS
    
    .cc_bottom FUNCTION_NAME.func


#undef FUNCTION_NAME


#define FUNCTION_NAME xua_4_to_3
    // int *xua_4_to_3(int *output, int *input, int count)
    // r0: argument 1, output (word aligned)
    // r1: argument 2, input  (word aligned)
    // r2: argument 3, count  (number of 3-byte chunks to write, must be > 0)
    // Returns pointer beyond last word that was written.

#define NSTACKWORDS   2
    .globl FUNCTION_NAME
    .globl FUNCTION_NAME.nstackwords
    .globl FUNCTION_NAME.maxthreads
    .globl FUNCTION_NAME.maxtimers
    .globl FUNCTION_NAME.maxchanends
    .linkset FUNCTION_NAME.nstackwords, NSTACKWORDS
    .linkset FUNCTION_NAME.threads, 0
    .linkset FUNCTION_NAME.maxtimers, 0
    .linkset FUNCTION_NAME.chanends, 0

    .cc_top FUNCTION_NAME.func, FUNCTION_NAME
    .type FUNCTION_NAME, @function
    
    .text
    .issue_mode dual
    .align 16

FUNCTION_NAME:   
    { dualentsp NSTACKWORDS     ; ldc r3, 8     }
    std    r4, r5, sp[0]
    { sub r2, r2, 1             ; nop           }
loop:
    { ldw  r11, r1[0]           ; add r1, r1, 4 }
    { shr  r11, r11, 8          ; sub r3, r3, 8 }
    zext r3, 5
    linsert r4, r5, r11, r3, 24
    { bf   r2, done             ; sub r2, r2, 1 }
    { bf   r3, loop             ; nop           }
    
    { stw  r5, r0[0]            ; add r5, r4, 0 }
    { add  r0, r0, 4            ; bu loop       }

done:
    { stw  r5, r0[0]            ; shr r3, r3, 4 }
    { bf r3, r4_has_no_data     ; add r0, r0, 4 }
    { stw    r4, r0[0]          ; add r0, r0, 4 }
r4_has_no_data: 
    ldd r4, r5, sp[0]
    retsp NSTACKWORDS
    
    .cc_bottom FUNCTION_NAME.func
    
#endif
