; mkfiles c: creates empty files c00, c01, ... (hex) in the current
; directory until one can't be created (at most 256); prints how many
.include "../../include/breadbin.inc"
.import argn, print_dec, newline
n   = $23
ap  = $24               ; 2: the argument
.segment "CODE"
        lda #'f'
        sta name
        lda #1
        jsr argn
        bcs @go
        sta ap
        stx ap+1
        ldy #0
        lda (ap),y
        sta name
@go:    lda #0
        sta n
        sta name+3
@l:     lda n
        lsr a
        lsr a
        lsr a
        lsr a
        tax
        lda hex,x
        sta name+1
        lda n
        and #15
        tax
        lda hex,x
        sta name+2
        lda #<name
        sta r0
        lda #>name
        sta r0+1
        lda #(O_WRONLY | O_CREAT)
        jsr SYS_OPEN
        bcs @done
        jsr SYS_CLOSE
        inc n
        bne @l
@done:  lda n
        ldx #0
        jsr print_dec
        jsr newline
        lda #0
        jmp SYS_EXIT

.segment "RODATA"
hex:    .byte "0123456789abcdef"
.segment "BSS"
name:   .res 4
