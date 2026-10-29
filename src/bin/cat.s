; cat: concatenate files (or stdin) to stdout
.include "../../include/c64os.inc"
.import argn, open_or_die, perr
fd = $23
idx = $24
.segment "CODE"
        lda argc
        cmp #2
        bcs @files
        lda #0
        jsr copy
        rts
@files: lda #1
        sta idx
@l:     lda idx
        jsr argn
        bcs @d
        ldy #O_RDONLY
        jsr open_or_die
        sta fd
        jsr copy
        lda fd
        jsr SYS_CLOSE
        inc idx
        jmp @l
@d:     rts
copy:   sta fd
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
        bcs @e
        lda r1
        ora r1+1
        beq @x
        lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        lda #1
        jsr SYS_WRITE
        bcs @x
        jmp @r
@e:     ldx #0
        ldy #0
        jsr perr
@x:     rts
.segment "BSS"
buf: .res 256
