; theme [name]: set screen colours (saved in /etc/theme, applied at boot)
.include "../../include/breadbin.inc"
.import print, eprint, argn
.importzp lp1, lp2
fd = $23
.segment "CODE"
start:  lda #1
        jsr argn
        bcc @named
        ; no argument: apply the saved theme (or the default)
        lda #<p_theme
        sta r0
        lda #>p_theme
        sta r0+1
        lda #O_RDONLY
        jsr SYS_OPEN
        bcs @def
        sta fd
        lda #<name
        sta r0
        lda #>name
        sta r0+1
        lda #15
        sta r1
        lda #0
        sta r1+1
        lda fd
        jsr SYS_READ
        ldx r1
        lda #0
        sta name,x
        dex
        bmi @d0
        lda name,x
        cmp #10
        bne @d0
        lda #0
        sta name,x
@d0:    lda fd
        jsr SYS_CLOSE
        lda #<name
        ldx #>name
        jsr find
        bcc apply
@def:   ldx #0
        jmp apply
@named: jsr find
        bcc @save
        lda #<s_list
        ldx #>s_list
        jsr eprint
        lda #1
        jmp SYS_EXIT
@save:  stx sel
        lda #<p_theme
        sta r0
        lda #>p_theme
        sta r0+1
        lda #(O_WRONLY | O_CREAT | O_TRUNC)
        jsr SYS_OPEN
        bcs @ap
        sta fd
        lda sel
        asl a
        asl a
        asl a
        clc
        adc #<names
        sta r0
        lda #>names
        adc #0
        sta r0+1
        lda #8
        sta r1
        lda #0
        sta r1+1
        lda fd
        jsr SYS_WRITE
        lda fd
        jsr SYS_CLOSE
@ap:    ldx sel
apply:  lda #ESC
        sta esc
        lda #'C'
        sta esc+1
        lda fg,x
        clc
        adc #32
        sta esc+2
        lda bg,x
        clc
        adc #32
        sta esc+3
        lda bd,x
        clc
        adc #32
        sta esc+4
        lda #<esc
        sta r0
        lda #>esc
        sta r0+1
        lda #5
        sta r1
        lda #0
        sta r1+1
        lda #1
        jmp SYS_WRITE

; find: A/X = name -> X = theme index, carry clear if known
find:   sta lp1
        stx lp1+1
        ldx #0
@t:     txa
        asl a
        asl a
        asl a
        clc
        adc #<names
        sta lp2
        lda #>names
        adc #0
        sta lp2+1
        ldy #0
@c:     lda (lp1),y
        cmp (lp2),y
        bne @n
        cmp #0
        beq @f
        iny
        bne @c
@n:     inx
        cpx #NTHEMES
        bne @t
        sec
        rts
@f:     clc
        rts
.segment "RODATA"
NTHEMES = 6
names:  .byte "green", 0, 0, 0
        .byte "c64", 0, 0, 0, 0, 0
        .byte "amber", 0, 0, 0
        .byte "mono", 0, 0, 0, 0
        .byte "paper", 0, 0, 0
        .byte "night", 0, 0, 0
fg:     .byte 13, 14, 8, 1, 0, 3
bg:     .byte 0, 6, 0, 0, 1, 6
bd:     .byte 0, 14, 0, 0, 15, 0
s_list: .byte "themes: green c64 amber mono paper night", 10, 0
p_theme: .byte "/etc/theme", 0
.segment "BSS"
name: .res 16
sel:  .res 1
esc:  .res 5
