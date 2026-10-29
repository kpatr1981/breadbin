; umount dir: detach a mounted drive
.include "../../include/c64os.inc"
.import argn, perr, eprint
.segment "CODE"
        lda #1
        jsr argn
        bcs @usage
        sta r0
        stx r0+1
        jsr SYS_UMOUNT
        bcc @ok
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
@ok:    rts
@usage: lda #<usage
        ldx #>usage
        jsr eprint
        lda #1
        jmp SYS_EXIT
.segment "RODATA"
usage: .byte "usage: umount dir", 10, 0
