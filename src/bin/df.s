; df: free space on / and /tmp
.include "../../include/c64os.inc"
.import print, print_dec_w, newline
.segment "CODE"
        lda #<hdr
        ldx #>hdr
        jsr print
        lda #<p_root
        ldx #>p_root
        jsr one
        lda #0
        sta mi
@m:     lda #<mbuf
        sta r0
        lda #>mbuf
        sta r0+1
        lda mi
        jsr SYS_MNTINFO
        bcs @n
        lda #<(mbuf+2)
        ldx #>(mbuf+2)
        jsr one
@n:     inc mi
        lda mi
        cmp #4
        bne @m
        rts
one:    sta r0
        stx r0+1
        sta name
        stx name+1
        lda #<buf
        sta r1
        lda #>buf
        sta r1+1
        jsr SYS_FSINFO
        bcs @r
        lda buf+6
        sta dev
        lda buf+2
        ldx buf+3
        ldy #7
        jsr print_dec_w
        lda buf+2
        sec
        sbc buf
        pha
        lda buf+3
        sbc buf+1
        tax
        pla
        ldy #7
        jsr print_dec_w
        lda buf
        ldx buf+1
        ldy #7
        jsr print_dec_w
        lda buf+4
        ldx #0
        ldy #7
        jsr print_dec_w
        lda #' '
        jsr pc
        lda name
        ldx name+1
        jsr print
        jsr newline
@r:     rts
pc:     ldy #1
        .import fputc
        jmp fputc
.segment "RODATA"
hdr:    .byte " blocks   used   free inodes", 10, 0
p_root: .byte "/", 0
p_tmp:  .byte "/tmp", 0
.segment "BSS"
buf:  .res 8
name: .res 2
dev:  .res 1
mi:   .res 1
mbuf: .res 34
