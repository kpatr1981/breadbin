; help: show /etc/help
.include "../../include/c64os.inc"
.import open_or_die
fd = $23
.segment "CODE"
        lda #<path
        ldx #>path
        ldy #O_RDONLY
        jsr open_or_die
        sta fd
@l:     lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        lda #0
        sta r1
        lda #1
        sta r1+1
        lda fd
        jsr SYS_READ
        bcs @d
        lda r1
        ora r1+1
        beq @d
        lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        lda #1
        jsr SYS_WRITE
        jmp @l
@d:     rts
.segment "RODATA"
path: .byte "/etc/help", 0
.segment "BSS"
buf: .res 256
