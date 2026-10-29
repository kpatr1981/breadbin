; ps: list processes
.include "../../include/breadbin.inc"
.import print, putc, newline, print_dec_w
slot = $23
.segment "CODE"
        lda #<hdr
        ldx #>hdr
        jsr print
        lda #0
        sta slot
@l:     lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        lda slot
        jsr SYS_PROCINFO
        bcs @n
        lda buf
        ldx #0
        ldy #4
        jsr print_dec_w
        lda buf+1
        ldx #0
        ldy #5
        jsr print_dec_w
        lda #' '
        jsr putc
        lda #' '
        jsr putc
        ldx buf+2
        lda states,x
        jsr putc
        lda buf+3
        and #SP_BG
        beq @fg
        lda #'&'
        bne @f
@fg:    lda #' '
@f:     jsr putc
        lda buf+4
        ldx #0
        ldy #4
        jsr print_dec_w
        lda #' '
        jsr putc
        lda #<(buf+5)
        ldx #>(buf+5)
        jsr print
        jsr newline
@n:     inc slot
        lda slot
        cmp #16
        bne @l
        rts
.segment "RODATA"
hdr:    .byte " pid ppid st  mem name", 10, 0
states: .byte "?rsz"
.segment "BSS"
buf: .res 16
