; stat file...: show inode information
.include "../../include/breadbin.inc"
.import argn, perr, print, print_dec, newline
.import ep2cal, print_date, dt_ep
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
        lda #<s_mod
        ldx #>s_mod
        ldy #8
        jsr when
        lda #<s_chg
        ldx #>s_chg
        ldy #12
        jsr when
        jsr newline
@n:     inc idx
        jmp @l
; when: newline, the label A/X, then the time at st+Y in full ("-" if 0)
when:   sty off
        pha
        txa
        pha
        jsr newline
        pla
        tax
        pla
        jsr print
        lda #0
        sta nz
        ldy off
        ldx #0
@c:     lda st,y
        sta dt_ep,x
        ora nz
        sta nz
        iny
        inx
        cpx #4
        bne @c
        lda nz
        bne @t
        lda #<s_none
        ldx #>s_none
        jmp print
@t:     jsr ep2cal
        lda #1
        jmp print_date

.segment "RODATA"
s_mod:   .byte "modify: ", 0
s_chg:   .byte "change: ", 0
s_none:  .byte "-", 0
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
st: .res 16
off: .res 1
nz: .res 1
