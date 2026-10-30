; pipe0: read(fd, buf, 0) on a pipe holding data must return 0 and leave
; buf alone; the data is still there for the next read. Prints "ok"/"bad".
.include "../../include/breadbin.inc"
.import print
rfd = $23
wfd = $24
.segment "CODE"
        jsr SYS_PIPE
        sta rfd
        stx wfd
        lda #<s_ab
        sta r0
        lda #>s_ab
        sta r0+1
        lda #2
        sta r1
        lda #0
        sta r1+1
        lda wfd
        jsr SYS_WRITE
        ldy #0
        lda #$55
@f:     sta buf,y
        iny
        bne @f
        jsr setbuf
        lda #0
        sta r1
        lda rfd
        jsr SYS_READ
        bcs @bad
        lda r1
        ora r1+1
        bne @bad
        ldy #0
@c:     lda buf,y
        cmp #$55
        bne @bad
        iny
        bne @c
        jsr setbuf
        lda #10
        sta r1
        lda rfd
        jsr SYS_READ
        bcs @bad
        lda r1
        cmp #2
        bne @bad
        lda buf
        cmp #'A'
        bne @bad
        lda #<s_ok
        ldx #>s_ok
        jsr print
        lda #0
        jmp SYS_EXIT
@bad:   lda #<s_bad
        ldx #>s_bad
        jsr print
        lda #1
        jmp SYS_EXIT
setbuf: lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        lda #0
        sta r1+1
        rts
.segment "RODATA"
s_ab:   .byte "AB"
s_ok:   .byte "ok", 10, 0
s_bad:  .byte "bad", 10, 0
.segment "BSS"
buf:    .res 256
