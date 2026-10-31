; writehold file: write "held" + newline to file and keep it open, sleeping
.include "../../include/breadbin.inc"
.import argn, perr
.segment "CODE"
        lda #1
        jsr argn
        sta r0
        stx r0+1
        lda #(O_WRONLY | O_CREAT | O_TRUNC)
        jsr SYS_OPEN
        bcs @err
        pha
        lda #<msg
        sta r0
        lda #>msg
        sta r0+1
        lda #5
        sta r1
        lda #0
        sta r1+1
        pla
        jsr SYS_WRITE
@s:     lda #$ff
        ldx #$7f
        jsr SYS_SLEEP
        jmp @s
@err:   ldx #0
        ldy #0
        jsr perr
        lda #1
        jmp SYS_EXIT
.segment "RODATA"
msg:    .byte "held", 10
