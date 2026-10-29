; uname: system name
.include "../../include/breadbin.inc"
.import print, argn
.importzp lp1
.segment "CODE"
        lda #1
        jsr argn
        bcs @s
        sta lp1
        stx lp1+1
        ldy #1
        lda (lp1),y
        cmp #'a'
        bne @s
        lda #<all
        ldx #>all
        jmp print
@s:     lda #<sys
        ldx #>sys
        jmp print
.segment "RODATA"
sys: .byte "breadbin", 10, 0
all: .byte "breadbin c64 0.2 6510 commodore-64", 10, 0
