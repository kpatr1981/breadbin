; target: A/X = destination argument -> `path`; if it names a directory,
; path = dest + "/" + basename(argv[1])
.include "../../include/c64os.inc"
.import argn, basename
.importzp lp1, lp2
.export target, path
.segment "CODE"
target: sta lp2
        stx lp2+1
        ldy #0
@c:     lda (lp2),y
        sta path,y
        beq @e
        iny
        cpy #62
        bne @c
        lda #0
        sta path,y
@e:     sty tlen
        lda #<path
        sta r0
        lda #>path
        sta r0+1
        lda #<stbuf
        sta r1
        lda #>stbuf
        sta r1+1
        jsr SYS_STAT
        bcs @r
        lda stbuf
        cmp #T_DIR
        bne @r
        lda #1
        jsr argn
        jsr basename
        sta lp1
        stx lp1+1
        ldx tlen
        lda path-1,x
        cmp #'/'
        beq @ns
        lda #'/'
        sta path,x
        inx
@ns:    ldy #0
@b:     lda (lp1),y
        sta path,x
        beq @r
        inx
        iny
        cpx #63
        bne @b
        lda #0
        sta path,x
@r:     rts
.segment "BSS"
path:  .res 64
stbuf: .res 8
tlen:  .res 1
