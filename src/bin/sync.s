; sync: write every changed disk block back now
.include "../../include/breadbin.inc"
.import perr
.segment "CODE"
        jsr SYS_SYNC
        bcc @r
        ldx #0
        ldy #0
        jsr perr
        lda #1
        jmp SYS_EXIT
@r:     rts
