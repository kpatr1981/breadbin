; clear: clear the screen
.include "../../include/c64os.inc"
.import putc
.segment "CODE"
        lda #12
        jmp putc
