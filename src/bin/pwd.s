; pwd: print working directory
.include "../../include/breadbin.inc"
.import print, newline
.segment "CODE"
        lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        lda #64
        jsr SYS_GETCWD
        lda #<buf
        ldx #>buf
        jsr print
        jmp newline
.segment "BSS"
buf: .res 64
