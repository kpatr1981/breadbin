; holdread file trigger: open file, wait until trigger exists and is not
; empty, then copy one read of the (still open) file to stdout
.include "../../include/breadbin.inc"
.import argn, perr
fd = $23
.segment "CODE"
        lda #1
        jsr argn
        sta r0
        stx r0+1
        lda #O_RDONLY
        jsr SYS_OPEN
        bcs @err
        sta fd
@poll:  lda #30
        ldx #0
        jsr SYS_SLEEP
        lda #2
        jsr argn
        sta r0
        stx r0+1
        lda #<st
        sta r1
        lda #>st
        sta r1+1
        jsr SYS_STAT
        bcs @poll
        lda st+2
        ora st+3
        ora st+4
        beq @poll
        lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        lda #255
        sta r1
        lda #0
        sta r1+1
        lda fd
        jsr SYS_READ
        bcs @err
        lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        lda #1
        jsr SYS_WRITE
        lda #0
        jmp SYS_EXIT
@err:   ldx #0
        ldy #0
        jsr perr
        lda #1
        jmp SYS_EXIT
.segment "BSS"
st:     .res 8
buf:    .res 256
