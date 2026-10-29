; echo: print arguments
.include "../../include/c64os.inc"
.import print, putc, newline, argn
.segment "CODE"
        lda #1
        sta $23
@l:     lda $23
        jsr argn
        bcs @end
        jsr print
        inc $23
        lda $23
        cmp argc
        bcs @end
        lda #' '
        jsr putc
        jmp @l
@end:   jmp newline
