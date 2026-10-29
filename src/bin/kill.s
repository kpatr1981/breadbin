; kill [-signal] pid...
.include "../../include/c64os.inc"
.import argn, parse_dec, perr, eprint
.importzp lp1
idx = $23
sig = $24
st  = $25
.segment "CODE"
        lda #SIGTERM
        sta sig
        lda #0
        sta st
        lda #1
        sta idx
        lda argc
        cmp #2
        bcc @usage
        lda #1
        jsr argn
        sta lp1
        stx lp1+1
        ldy #0
        lda (lp1),y
        cmp #'-'
        bne @pids
        lda lp1
        clc
        adc #1
        ldx lp1+1
        bcc @p
        inx
@p:     jsr parse_dec
        bcs @usage
        sta sig
        inc idx
@pids:  lda idx
        jsr argn
        bcs @done
        jsr parse_dec
        bcs @usage
        ldx sig
        jsr SYS_KILL
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
        jmp @pids
@done:  lda st
        jmp SYS_EXIT
@usage: lda #<usage
        ldx #>usage
        jsr eprint
        lda #1
        jmp SYS_EXIT
.segment "RODATA"
usage: .byte "usage: kill [-signal] pid...", 10, 0
