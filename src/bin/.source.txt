; clear: clear the screen
.include "../../include/breadbin.inc"
.import putc
.segment "CODE"
        lda #12
        jmp putc
