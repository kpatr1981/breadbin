; readtime file...: read the files to the end; prints the jiffies it took
.include "../../include/breadbin.inc"
.import argn, perr, print_dec, newline
t0  = $23
idx = $25
fd  = $26
.segment "CODE"
        jsr SYS_TIME
        sta t0
        stx t0+1
        lda #1
        sta idx
@f:     lda idx
        jsr argn
        bcs @done
        sta r0
        stx r0+1
        lda #O_RDONLY
        jsr SYS_OPEN
        bcs @err
        sta fd
@r:     lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        lda #0
        sta r1
        lda #1
        sta r1+1
        lda fd
        jsr SYS_READ
        bcs @err
        lda r1
        ora r1+1
        bne @r
        lda fd
        jsr SYS_CLOSE
        inc idx
        bne @f
@done:  jsr SYS_TIME
        sec
        sbc t0
        pha
        txa
        sbc t0+1
        tax
        pla
        jsr print_dec
        jsr newline
        lda #0
        jmp SYS_EXIT
@err:   ldx #0
        ldy #0
        jsr perr
        lda #1
        jmp SYS_EXIT
.segment "BSS"
buf:    .res 256
