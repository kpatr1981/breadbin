; mount [drive dir]: list mounts, or mount drive 9-11 on a directory
;   mount 9 /mnt     a Breadbin disk (with directories) or a normal C64 disk
.include "../../include/breadbin.inc"
.import argn, parse_dec, perr, print, eprint, putc, newline, print_dec
idx = $23
.segment "CODE"
        lda argc
        cmp #3
        beq @mount
        cmp #1
        beq @list
        lda #<usage
        ldx #>usage
        jsr eprint
        lda #1
        jmp SYS_EXIT
@mount: lda #1
        jsr argn
        jsr parse_dec
        bcs @bad
        sta drv
        lda #2
        jsr argn
        sta r0
        stx r0+1
        lda drv
        jsr SYS_MOUNT
        bcc @ok
        pha
        lda #2
        jsr argn
        pha
        txa
        tay
        pla
        tax
        pla
        jsr perr
        lda #1
        jmp SYS_EXIT
@bad:   lda #EINVAL
        ldx #0
        ldy #0
        jsr perr
        lda #1
        jmp SYS_EXIT
@ok:    rts
@list:  lda #<root
        ldx #>root
        jsr print
        lda #0
        sta idx
@l:     lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        lda idx
        jsr SYS_MNTINFO
        bcs @n
        lda buf
        bne @drv
        lda #<s_reu
        ldx #>s_reu
        jsr print
        jmp @on
@drv:   lda #<s_drv
        ldx #>s_drv
        jsr print
        lda buf
        ldx #0
        jsr print_dec
@on:    lda #<s_on
        ldx #>s_on
        jsr print
        lda #<(buf+2)
        ldx #>(buf+2)
        jsr print
        lda buf+1
        beq @c64
        lda #<s_cbm
        ldx #>s_cbm
        jsr print
        jmp @nl
@c64:   lda #<s_c64
        ldx #>s_c64
        jsr print
@nl:    jsr newline
@n:     inc idx
        lda idx
        cmp #4
        bne @l
        rts
.segment "RODATA"
usage: .byte "usage: mount [drive dir]", 10, 0
root:  .byte "drive 8 on / (c64fs)", 10, 0
s_reu: .byte "reu", 0
s_drv: .byte "drive ", 0
s_on:  .byte " on ", 0
s_c64: .byte " (c64fs)", 0
s_cbm: .byte " (cbm dos)", 0
.segment "BSS"
drv: .res 1
buf: .res 34
