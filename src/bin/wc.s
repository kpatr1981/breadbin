; wc [file...]: count lines, words, bytes
.include "../../include/c64os.inc"
.import argn, open_or_die, getc, set_input, print_dec_w, print, newline, putc
lines = $23
words = $25
bytes = $27
inw   = $29
idx   = $2a
fd    = $2b
.segment "CODE"
        lda argc
        cmp #2
        bcs @files
        lda #0
        jsr count
        lda #0
        sta fname+1
        jmp report
@files: lda #1
        sta idx
@l:     lda idx
        jsr argn
        bcs @d
        sta fname
        stx fname+1
        ldy #O_RDONLY
        jsr open_or_die
        sta fd
        jsr count
        lda fd
        jsr SYS_CLOSE
        jsr report
        inc idx
        jmp @l
@d:     rts
count:  jsr set_input
        lda #0
        ldx #5
@z:     sta lines,x
        dex
        bpl @z
        sta inw
@c:     jsr getc
        bcs @e
        pha
        inc bytes
        bne @b
        inc bytes+1
@b:     pla
        cmp #10
        bne @nl
        inc lines
        bne @nl
        inc lines+1
@nl:    cmp #' '+1
        bcc @sp
        lda inw
        bne @c
        inc inw
        inc words
        bne @c
        inc words+1
        jmp @c
@sp:    lda #0
        sta inw
        jmp @c
@e:     rts
report: lda lines
        ldx lines+1
        ldy #6
        jsr print_dec_w
        lda words
        ldx words+1
        ldy #7
        jsr print_dec_w
        lda bytes
        ldx bytes+1
        ldy #7
        jsr print_dec_w
        lda fname+1
        beq @n
        lda #' '
        jsr putc
        lda fname
        ldx fname+1
        jsr print
@n:     jmp newline
.segment "BSS"
fname: .res 2
