; hexdump [file]: show bytes in hex and ascii, 8 per line
.include "../../include/c64os.inc"
.import argn, open_or_die, getc, set_input, putc, newline, print_hex
off = $23               ; 2
n   = $25
.segment "CODE"
        lda #1
        jsr argn
        bcs @in
        ldy #O_RDONLY
        jsr open_or_die
        jmp @go
@in:    lda #0
@go:    jsr set_input
        lda #0
        sta off
        sta off+1
@line:  ldx #0
@rd:    stx n
        jsr getc
        ldx n
        bcs @eof
        sta row,x
        inx
        cpx #8
        bne @rd
        stx n
        jsr show
        jmp @line
@eof:   stx n
        cpx #0
        beq @d
        jsr show
@d:     rts
show:   lda off+1
        jsr print_hex
        lda off
        jsr print_hex
        lda #':'
        jsr putc
        ldx #0
@h:     stx i
        lda #' '
        jsr putc
        ldx i
        cpx n
        bcs @sp
        lda row,x
        jsr print_hex
        jmp @hn
@sp:    lda #' '
        jsr putc
        lda #' '
        jsr putc
@hn:    ldx i
        inx
        cpx #8
        bne @h
        lda #' '
        jsr putc
        lda #' '
        jsr putc
        ldx #0
@a:     stx i
        cpx n
        bcs @ad
        lda row,x
        cmp #$20
        bcc @dot
        cmp #$7f
        bcc @p
@dot:   lda #'.'
@p:     jsr putc
        ldx i
        inx
        bne @a
@ad:    jsr newline
        lda off
        clc
        adc #8
        sta off
        bcc @r
        inc off+1
@r:     rts
.segment "BSS"
row: .res 8
i:   .res 1
