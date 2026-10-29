; count: print an increasing number every second, forever
.include "../../include/breadbin.inc"
.import print_dec, newline
n = $23
.segment "CODE"
        lda #0
        sta n
        sta n+1
@l:     lda n
        ldx n+1
        jsr print_dec
        jsr newline
        inc n
        bne @s
        inc n+1
@s:     lda #60
        ldx #0
        jsr SYS_SLEEP
        jmp @l
