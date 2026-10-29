; cp: copy a file (into a directory if the target is one)
.include "../../include/c64os.inc"
.import argn, perr, eprint, open_or_die, target, path
in  = $23
out = $24
.segment "CODE"
        lda argc
        cmp #3
        beq @ok
        lda #<usage
        ldx #>usage
        jsr eprint
        lda #1
        jmp SYS_EXIT
@ok:    lda #2
        jsr argn
        jsr target
        lda #1
        jsr argn
        ldy #O_RDONLY
        jsr open_or_die
        sta in
        lda #<path
        ldx #>path
        ldy #(O_WRONLY | O_CREAT | O_TRUNC)
        jsr open_or_die
        sta out
@l:     lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        lda #0
        sta r1
        lda #1
        sta r1+1
        lda in
        jsr SYS_READ
        bcs @err
        lda r1
        ora r1+1
        beq @done
        lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        lda out
        jsr SYS_WRITE
        bcs @err
        jmp @l
@err:   ldx #<path
        ldy #>path
        jsr perr
        lda #1
        jmp SYS_EXIT
@done:  rts
.segment "RODATA"
usage: .byte "usage: cp from to", 10, 0
.segment "BSS"
buf: .res 256
