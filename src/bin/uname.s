; uname: system name
.include "../../include/c64os.inc"
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
sys: .byte "c64os", 10, 0
all: .byte "c64os c64 0.1 6510 commodore-64", 10, 0
