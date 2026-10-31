; smallw file: write 200 bytes to file one byte per write(); prints the
; jiffies it took (open to close)
.include "../../include/breadbin.inc"
.import argn, perr, print_dec, newline
fd = $23
n  = $24
t0 = $25
.segment "CODE"
        jsr SYS_TIME
        sta t0
        stx t0+1
        lda #1
        jsr argn
        sta r0
        stx r0+1
        lda #(O_WRONLY | O_CREAT | O_TRUNC)
        jsr SYS_OPEN
        bcs @err
        sta fd
        lda #200
        sta n
@l:     lda n
        and #$0f
        ora #'a'
        sta ch
        lda #<ch
        sta r0
        lda #>ch
        sta r0+1
        lda #1
        sta r1
        lda #0
        sta r1+1
        lda fd
        jsr SYS_WRITE
        bcs @err
        dec n
        bne @l
        lda fd
        jsr SYS_CLOSE
        jsr SYS_TIME
        sec
        sbc t0
        pha
        txa
        sbc t0+1
        tax
        pla
        jsr print_dec
        jsr newline
        lda #0
        jmp SYS_EXIT
@err:   ldx #0
        ldy #0
        jsr perr
        lda #1
        jmp SYS_EXIT
.segment "BSS"
ch:     .res 1
