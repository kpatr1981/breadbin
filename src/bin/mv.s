; mv: rename a file or directory (into a directory if the target is one)
.include "../../include/breadbin.inc"
.import argn, perr, eprint, basename, target, path
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
        sta r0
        stx r0+1
        lda #<path
        sta r1
        lda #>path
        sta r1+1
        jsr SYS_RENAME
        bcc @r
        pha
        lda #1
        jsr argn
        pha
        txa
        tay
        pla
        tax
        pla
        jsr perr
        lda #1
        jmp SYS_EXIT
@r:     rts
.segment "RODATA"
usage: .byte "usage: mv from to", 10, 0
