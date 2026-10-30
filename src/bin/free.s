; free: memory usage
.include "../../include/breadbin.inc"
.import print, print_dec_w, newline
.segment "CODE"
        lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        jsr SYS_MEMINFO
        lda #<hdr
        ldx #>hdr
        jsr print
        lda #<s_mem
        ldx #>s_mem
        jsr print
        ; total, used, free in bytes/1024 = pages/4
        lda buf+1
        jsr kb
        lda buf+1
        sec
        sbc buf
        jsr kb
        lda buf
        jsr kb
        jsr newline
        lda buf+2
        beq @nr
        lda #<s_reu
        ldx #>s_reu
        ldy buf+5
        cpy #2
        bne @r1
        lda #<s_geo
        ldx #>s_geo
@r1:    jsr print
        lda buf+2
        ldx #0
        stx tmp
        ; banks * 64
        ldy #6
@m:     asl a
        rol tmp
        dey
        bne @m
        ldx tmp
        ldy #7
        jsr print_dec_w
        jsr newline
@nr:    lda #<s_proc
        ldx #>s_proc
        jsr print
        lda buf+3
        ldx #0
        ldy #2
        jsr print_dec_w
        lda #'/'
        jsr putc_
        lda buf+4
        ldx #0
        ldy #1
        jsr print_dec_w
        jmp newline
kb:     lsr a
        lsr a
        ldx #0
        ldy #7
        jmp print_dec_w
putc_:  ldy #1
        .import fputc
        jmp fputc
.segment "RODATA"
hdr:    .byte "         total   used   free (k)", 10, 0
s_mem:  .byte "mem:  ", 0
s_reu:  .byte "reu:  ", 0
s_geo:  .byte "georam:", 0
s_proc: .byte "processes: ", 0
.segment "BSS"
buf: .res 8
tmp: .res 1
