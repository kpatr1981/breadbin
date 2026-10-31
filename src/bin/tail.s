; tail [-n] [file]: the last n (10) lines. Keeps the last 2 KB of the input
; in a ring, so lines further back than that are gone.
.include "../../include/breadbin.inc"
.import argn, open_or_die, getc, set_input, parse_dec
RING = 2048
n     = $23
idx   = $24
p     = $25             ; 2: where the next byte goes (ring .. ring+RING-1)
full  = $27             ; the ring has wrapped: it holds RING bytes
q     = $28             ; 2: scanning back from the end
avail = $2a             ; 2: bytes in the ring
rem   = $2c             ; 2: bytes not looked at yet
first = $2e
.segment "CODE"
        lda #10
        sta n
        lda #1
        sta idx
        jsr argn
        bcs @in
        sta q
        stx q+1
        ldy #0
        lda (q),y
        cmp #'-'
        bne @file
        lda q
        clc
        adc #1
        ldx q+1
        bcc @pd
        inx
@pd:    jsr parse_dec
        bcs @file
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
        lda #<ring
        sta p
        lda #>ring
        sta p+1
        lda #0
        sta full
@rd:    jsr getc
        bcs @end
        ldy #0
        sta (p),y
        inc p
        bne @rd
        inc p+1
        lda p+1
        cmp #>(ring+RING)
        bne @rd
        lda p
        cmp #<(ring+RING)
        bne @rd
        lda #<ring
        sta p
        lda #>ring
        sta p+1
        lda #1
        sta full
        jmp @rd

@end:   lda n
        bne @cnt
@exit:  jmp exit
@cnt:
        lda full
        bne @f
        lda p
        sec
        sbc #<ring
        sta avail
        lda p+1
        sbc #>ring
        sta avail+1
        jmp @sc
@f:     lda #<RING
        sta avail
        lda #>RING
        sta avail+1
@sc:    lda avail
        ora avail+1
        beq @exit
        lda avail
        sta rem
        lda avail+1
        sta rem+1
        lda p
        sta q
        lda p+1
        sta q+1
        lda #1
        sta first
        ; walk back from the end: the byte at q has been looked at already
@step:  lda rem
        ora rem+1
        beq @oldest
        jsr qdec
        lda rem
        bne @d
        dec rem+1
@d:     dec rem
        ldy #0
        lda (q),y
        ldx first
        beq @chk
        ldx #0              ; the last byte belongs to the last line,
        stx first           ; newline or not
        jmp @step
@chk:   cmp #10
        bne @step
        dec n
        bne @step
        ; q is at the newline before the first wanted line
        jsr setlen
        lda len
        bne @l1
        dec len+1
@l1:    dec len
        jsr qinc
        jmp @print
@oldest:
        jsr setlen
@print: ; from q, len bytes, in two runs if it wraps
        lda len
        ora len+1
        bne @more
        jmp exit
@more:
        lda q
        sta r0
        lda q+1
        sta r0+1
        ; to the end of the ring: ring+RING - q
        lda #<(ring+RING)
        sec
        sbc q
        sta r1
        lda #>(ring+RING)
        sbc q+1
        sta r1+1
        ; min(that, len)
        lda r1+1
        cmp len+1
        bcc @w
        bne @all
        lda r1
        cmp len
        bcc @w
@all:   lda len
        sta r1
        lda len+1
        sta r1+1
@w:     lda r1
        pha
        lda r1+1
        pha
        lda #1
        jsr SYS_WRITE
        pla
        sta r1+1
        pla
        sta r1
        lda len
        sec
        sbc r1
        sta len
        lda len+1
        sbc r1+1
        sta len+1
        lda #<ring          ; the second run starts at the ring's beginning
        sta q
        lda #>ring
        sta q+1
        jmp @print
exit:   lda #0
        jmp SYS_EXIT

; setlen: len = avail - rem (the bytes from q to the end)
setlen: lda avail
        sec
        sbc rem
        sta len
        lda avail+1
        sbc rem+1
        sta len+1
        rts

qdec:   lda q
        bne @d
        dec q+1
@d:     dec q
        lda q+1
        cmp #>ring
        bne @r
        lda q
        cmp #<ring
        bcs @r
        lda #<(ring+RING-1)
        sta q
        lda #>(ring+RING-1)
        sta q+1
@r:     rts
qinc:   inc q
        bne @c
        inc q+1
@c:     lda q+1
        cmp #>(ring+RING)
        bne @r
        lda q
        cmp #<(ring+RING)
        bne @r
        lda #<ring
        sta q
        lda #>ring
        sta q+1
@r:     rts

.segment "BSS"
len:    .res 2          ; bytes to print
ring:   .res RING
