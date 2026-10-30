; spin: a fixed amount of CPU work (~3.3 M cycles); prints the jiffies it took
.include "../../include/breadbin.inc"
.import print_dec, newline
t0 = $23
k  = $25
.segment "CODE"
        jsr SYS_TIME
        sta t0
        stx t0+1
        lda #10
        sta k
        ldy #0
@o:     ldx #0
@i:     dex
        bne @i
        dey
        bne @o
        dec k
        bne @o
        jsr SYS_TIME
        sec
        sbc t0
        pha
        txa
        sbc t0+1
        tax
        pla
        jsr print_dec
        jsr newline
        lda #0
        jmp SYS_EXIT
