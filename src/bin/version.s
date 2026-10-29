; version: print the c64os version
.include "../../include/c64os.inc"
.import print
.segment "CODE"
        lda #<s
        ldx #>s
        jmp print
.segment "RODATA"
s: .byte "c64os 0.2", 10, 0
