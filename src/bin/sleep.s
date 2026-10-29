; sleep seconds
.include "../../include/c64os.inc"
.import argn, parse_dec, eprint
n = $23
.segment "CODE"
        lda #1
        jsr argn
        bcs @usage
        jsr parse_dec
        bcs @usage
        sta n
        stx n+1
@l:     lda n
        ora n+1
        beq @d
        lda #60
        ldx #0
        jsr SYS_SLEEP
        lda n
        bne @dl
        dec n+1
@dl:    dec n
        jmp @l
@d:     rts
@usage: lda #<usage
        ldx #>usage
        jsr eprint
        lda #1
        jmp SYS_EXIT
.segment "RODATA"
usage: .byte "usage: sleep seconds", 10, 0
