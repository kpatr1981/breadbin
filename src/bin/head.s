; head [-n] [file]: first n (10) lines
.include "../../include/breadbin.inc"
.import argn, open_or_die, getc, set_input, putc, parse_dec
.importzp lp1
n   = $23
idx = $24
.segment "CODE"
        lda #10
        sta n
        lda #1
        sta idx
        jsr argn
        bcs @in
        sta lp1
        stx lp1+1
        ldy #0
        lda (lp1),y
        cmp #'-'
        bne @file
        lda lp1
        clc
        adc #1
        ldx lp1+1
        bcc @p
        inx
@p:     jsr parse_dec
        sta n
        inc idx
@file:  lda idx
        jsr argn
        bcs @in
        ldy #O_RDONLY
        jsr open_or_die
        jmp @go
@in:    lda #0
@go:    jsr set_input
        lda n
        beq @d
@c:     jsr getc
        bcs @d
        pha
        jsr putc
        pla
        cmp #10
        bne @c
        dec n
        bne @c
@d:     rts
