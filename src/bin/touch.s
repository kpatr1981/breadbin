; touch: create each file that doesn't exist yet. Inodes have no timestamps,
; so a file that exists stays as it is.
.include "../../include/breadbin.inc"
.import argn, perr, eprint
idx  = $23
st   = $24
path = $25
.segment "CODE"
        lda #0
        sta st
        lda argc
        cmp #2
        bcs @go
        lda #<usage
        ldx #>usage
        jsr eprint
        lda #1
        jmp SYS_EXIT
@go:    lda #1
        sta idx
@l:     lda idx
        jsr argn
        bcs @d
        sta path
        stx path+1
        sta r0
        stx r0+1
        lda #O_RDONLY       ; directories and CBM DOS files exist too
        jsr SYS_OPEN
        bcc @c
        cmp #ENOENT
        bne @e
        lda path
        sta r0
        lda path+1
        sta r0+1
        lda #(O_WRONLY | O_CREAT)
        jsr SYS_OPEN
        bcs @e
@c:     jsr SYS_CLOSE
        bcc @n
@e:     ldx path
        ldy path+1
        jsr perr
        lda #1
        sta st
@n:     inc idx
        jmp @l
@d:     lda st
        jmp SYS_EXIT
.segment "RODATA"
usage: .byte "usage: touch name...", 10, 0
