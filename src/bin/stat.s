; stat file...: show inode information
.include "../../include/c64os.inc"
.import argn, perr, print, print_dec, newline
idx = $23
cur = $24
.segment "CODE"
        lda #1
        sta idx
@l:     lda idx
        jsr argn
        bcc @a
        rts
@a:     sta cur
        stx cur+1
        sta r0
        stx r0+1
        lda #<st
        sta r1
        lda #>st
        sta r1+1
        jsr SYS_STAT
        bcc @ok
        ldx cur
        ldy cur+1
        jsr perr
        jmp @n
@ok:    lda #<s_file
        ldx #>s_file
        jsr print
        lda cur
        ldx cur+1
        jsr print
        lda #<s_type
        ldx #>s_type
        jsr print
        lda st
        asl a
        asl a
        asl a
        clc
        adc #<types
        ldx #>types
        bcc @t
        inx
@t:     jsr print
        lda #<s_size
        ldx #>s_size
        jsr print
        lda st+2
        ldx st+3
        jsr print_dec
        lda #<s_ino
        ldx #>s_ino
        jsr print
        lda st+5
        ldx #0
        jsr print_dec
        lda #<s_links
        ldx #>s_links
        jsr print
        lda st+1
        ldx #0
        jsr print_dec
        lda #<s_dev
        ldx #>s_dev
        jsr print
        lda st+6
        ldx #0
        jsr print_dec
        jsr newline
@n:     inc idx
        jmp @l
.segment "RODATA"
s_file:  .byte "  file: ", 0
s_type:  .byte 10, "  type: ", 0
s_size:  .byte "  size: ", 0
s_ino:   .byte 10, " inode: ", 0
s_links: .byte "  links: ", 0
s_dev:   .byte "  dev: ", 0
types:   .byte "?", 0, 0, 0, 0, 0, 0, 0
         .byte "file", 0, 0, 0, 0
         .byte "dir", 0, 0, 0, 0, 0
         .byte "device", 0, 0
.segment "BSS"
st: .res 8
