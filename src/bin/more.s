; more [file]: page through text, RETURN for the next page, q to quit
.include "../../include/c64os.inc"
.import argn, open_or_die, getc, set_input, putc, print
PAGE = 22
n   = $23
con = $24
col = $25
.segment "CODE"
        lda #<devcon
        ldx #>devcon
        ldy #O_RDONLY
        jsr open_or_die
        sta con
        lda #1
        jsr argn
        bcs @in
        ldy #O_RDONLY
        jsr open_or_die
        jmp @go
@in:    lda #0
@go:    jsr set_input
@page:  lda #PAGE
        sta n
        lda #0
        sta col
@c:     jsr getc
        bcs @d
        pha
        jsr putc
        pla
        cmp #10
        beq @nl
        inc col
        lda col
        cmp #40
        bcc @c
@nl:    lda #0
        sta col
        dec n
        bne @c
        lda #<prompt
        ldx #>prompt
        jsr print
        lda #<kb
        sta r0
        lda #>kb
        sta r0+1
        lda #8
        sta r1
        lda #0
        sta r1+1
        lda con
        jsr SYS_READ
        lda kb
        cmp #'q'
        beq @d
        jmp @page
@d:     rts
.segment "RODATA"
devcon: .byte "/dev/console", 0
prompt: .byte "--more--", 0
.segment "BSS"
kb: .res 8
