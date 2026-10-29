; mkdir: SYS_MKDIR on each argument
.include "../../include/breadbin.inc"
.import argn, perr, eprint
idx = $23
st  = $24
.segment "CODE"
        lda #0
        sta st
        lda argc
        cmp #2
        bcs @go
        lda #<usage
        ldx #>usage
        jsr eprint
        lda #1
        jmp SYS_EXIT
@go:    lda #1
        sta idx
@l:     lda idx
        jsr argn
        bcs @d
        sta r0
        stx r0+1
        jsr SYS_MKDIR
        bcc @n
        pha
        lda idx
        jsr argn
        pha
        txa
        tay
        pla
        tax
        pla
        jsr perr
        lda #1
        sta st
@n:     inc idx
        jmp @l
@d:     lda st
        jmp SYS_EXIT
.segment "RODATA"
usage: .byte "usage: mkdir name...", 10, 0
