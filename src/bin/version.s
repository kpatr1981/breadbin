; version: print the Breadbin version
.include "../../include/breadbin.inc"
.import print
.segment "CODE"
        lda #<s
        ldx #>s
        jmp print
.segment "RODATA"
s: .byte "breadbin 0.4 by kpatronas@gmail.com", 10, 0
