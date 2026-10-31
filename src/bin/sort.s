; sort [-r] [file]: sort lines (up to 8 KB of text, 255 lines; -r reverses)
.include "../../include/breadbin.inc"
.import argn, open_or_die, getc, set_input, eprint, print, newline
.importzp lp1, lp2
TEXT = 8192
MAXL = 255
idx   = $23
n     = $24             ; lines
p     = $25             ; 2: next free byte of text
atstart = $27           ; the next byte starts a line
rev   = $28
i     = $29
j     = $2a
klo   = $2b
khi   = $2c
.segment "CODE"
        lda #0
        sta rev
        sta n
        lda #1
        sta idx
        sta atstart
        jsr argn
        bcs @in
        sta lp1
        stx lp1+1
        ldy #0
        lda (lp1),y
        cmp #'-'
        bne @file
        iny
        lda (lp1),y
        cmp #'r'
        bne @file
        inc rev
        inc idx
@file:  lda idx
        jsr argn
        bcs @in
        ldy #O_RDONLY
        jsr open_or_die
        jmp @go
@in:    lda #0
@go:    jsr set_input
        lda #<text
        sta p
        lda #>text
        sta p+1
@rd:    jsr getc
        bcs @eof
        ldx atstart
        beq @ch
        ldx n               ; the first byte of a line: remember where
        cpx #MAXL
        bcs toomany
        pha
        lda p
        sta plo,x
        lda p+1
        sta phi,x
        inc n
        lda #0
        sta atstart
        pla
@ch:    cmp #10
        bne @st
        inc atstart         ; the next byte starts a line ...
        lda #0              ; ... and a NUL ends this one
@st:    jsr store
        jmp @rd
@eof:   lda atstart
        bne @in_
        lda #0              ; the last line had no newline
        jsr store
@in_:   jsr sort
        lda #0
        sta i
@o:     lda i
        cmp n
        beq exit
        tax
        lda rev
        beq @fw
        lda n               ; -r: from the end
        sec
        sbc i
        tax
        dex
@fw:    lda plo,x
        ldy phi,x
        pha
        tya
        tax
        pla
        jsr print
        jsr newline
        inc i
        jmp @o
exit:   lda #0
        jmp SYS_EXIT

; store: A -> text at p; "input too large" when the text is full
store:  ldx p+1
        cpx #>(text+TEXT)
        bne @ok
        ldx p
        cpx #<(text+TEXT)
        beq toobig
@ok:
        ldy #0
        sta (p),y
        inc p
        bne @r
        inc p+1
@r:     rts

toobig: lda #<s_big
        ldx #>s_big
        jmp die
toomany:
        lda #<s_many
        ldx #>s_many
die:    jsr eprint
        lda #1
        jmp SYS_EXIT

; sort: insertion sort of the line pointers, by byte value
sort:   lda n
        cmp #2
        bcc @r
        lda #1
        sta i
@outer: ldx i
        lda plo,x
        sta klo
        lda phi,x
        sta khi
        stx j
@inner: ldx j
        beq @place
        dex                 ; line j-1 against the key
        lda plo,x
        sta lp1
        lda phi,x
        sta lp1+1
        lda klo
        sta lp2
        lda khi
        sta lp2+1
        jsr cmpgt
        bcc @place
        ldx j               ; shift it up
        lda plo-1,x
        sta plo,x
        lda phi-1,x
        sta phi,x
        dec j
        jmp @inner
@place: ldx j
        lda klo
        sta plo,x
        lda khi
        sta phi,x
        inc i
        lda i
        cmp n
        bne @outer
@r:     rts

; cmpgt: carry set if the string at lp1 sorts after the one at lp2
cmpgt:  ldy #0
@l:     lda (lp1),y
        cmp (lp2),y
        bne @r              ; (carry: lp1's byte is the larger)
        cmp #0
        beq @eq
        iny
        bne @l
@eq:    clc
@r:     rts

.segment "RODATA"
s_big:  .byte "sort: input too large", 10, 0
s_many: .byte "sort: too many lines", 10, 0
.segment "BSS"
plo:    .res MAXL
phi:    .res MAXL
text:   .res TEXT
