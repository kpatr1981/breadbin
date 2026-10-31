; edit [file]: a small full-screen text editor
;
;   cursor keys move, HOME = start of line, DEL = backspace, RETURN = new line
;   ^O or F1  save          ^X or F7  quit (twice if there are unsaved changes)
;   ^K        delete line
;
; The screen is driven through the console: raw key mode (conmode) and
; the ESC = / ESC K / ESC R escapes. Rows 0-23 show text (39 columns),
; row 24 is the status line.
.include "../../include/breadbin.inc"
.import argn, print

TEXTMAX = 8192
ROWS    = 24
COLS    = 39

p    = $23              ; scratch pointer
q    = $25
cur  = $27              ; cursor offset in text
top  = $29              ; offset of the first line on screen
t16  = $2b

.segment "BSS"
text:   .res TEXTMAX
tlen:   .res 2
fname:  .res 2
dirty:  .res 1
warned: .res 1
cx:     .res 1
cy:     .res 1
want:   .res 1          ; column wanted by up/down
row:    .res 1
fd:     .res 1
key:    .res 1
obuf:   .res 64
olen:   .res 1
msg:    .res 2          ; status message (0 = default)
tmp:    .res 2

.segment "CODE"
start:  lda #0
        sta tlen
        sta tlen+1
        sta cur
        sta cur+1
        sta top
        sta top+1
        sta dirty
        sta warned
        sta msg+1
        sta fname+1
        lda #1
        jsr argn
        bcs @new
        sta fname
        stx fname+1
        jsr load
@new:   lda #1
        jsr SYS_CONMODE
        jsr redraw

main:   jsr getkey
        sta key
        lda #0
        sta msg+1
        lda key
        cmp #$18            ; ^X
        beq @quit
        cmp #K_F7
        beq @quit
        lda #0
        sta warned
        lda key
        cmp #$0f            ; ^O
        beq @save
        cmp #K_F1
        beq @save
        cmp #K_LEFT
        beq @left
        cmp #K_RIGHT
        beq @right
        cmp #K_UP
        beq @up
        cmp #K_DOWN
        beq @down
        cmp #K_HOME
        beq @home
        cmp #K_DEL
        beq @del
        cmp #$0b            ; ^K
        beq @kill
        cmp #K_RET
        beq @ins
        cmp #$20
        bcc main
        cmp #$7f
        bcs main
@ins:   jsr insert
        jmp @draw
@quit:  lda dirty
        beq @bye
        lda warned
        bne @bye
        inc warned
        lda #<m_unsaved
        ldx #>m_unsaved
        jsr set_msg
        jmp @draw
@bye:   lda #0
        jsr SYS_CONMODE
        lda #<s_clear
        ldx #>s_clear
        jsr print
        lda #0
        jmp SYS_EXIT
@save:  jsr save
        jmp @draw
@left:  jsr cur_dec
        jmp @hmove
@right: jsr cur_inc
        jmp @hmove
@home:  jsr line_start_cur
        jmp @hmove
@up:    jsr move_up
        jmp @draw
@down:  jsr move_down
        jmp @draw
@del:   lda cur
        ora cur+1
        bne @dok
        jmp main
@dok:   jsr cur_dec
        jsr delete
        jmp @draw
@kill:  jsr kill_line
        jmp @draw
@hmove: jsr calc_col
        lda cx
        sta want
@draw:  jsr redraw
        jmp main

set_msg:
        sta msg
        stx msg+1
        rts

getkey: lda #<key
        sta r0
        lda #>key
        sta r0+1
        lda #1
        sta r1
        lda #0
        sta r1+1
        lda #0
        jsr SYS_READ
        bcs @eof
        lda r1
        beq @eof
        lda key
        rts
@eof:   lda #$18            ; end of input: quit
        rts

; ---------------------------------------------------------------------
; file i/o
load:   lda fname
        sta r0
        lda fname+1
        sta r0+1
        lda #O_RDONLY
        jsr SYS_OPEN
        bcs @r
        sta fd
        lda #<text
        sta r0
        lda #>text
        sta r0+1
        lda #<TEXTMAX
        sta r1
        lda #>TEXTMAX
        sta r1+1
        lda fd
        jsr SYS_READ
        bcs @c
        lda r1
        sta tlen
        lda r1+1
        sta tlen+1
@c:     lda fd
        jsr SYS_CLOSE
@r:     rts

save:   lda fname+1
        bne @have
        lda #<m_noname
        ldx #>m_noname
        jmp set_msg
@have:  lda fname
        sta r0
        lda fname+1
        sta r0+1
        lda #(O_WRONLY | O_CREAT | O_TRUNC)
        jsr SYS_OPEN
        bcs @err
        sta fd
        lda #<text
        sta r0
        lda #>text
        sta r0+1
        lda tlen
        sta r1
        lda tlen+1
        sta r1+1
        lda fd
        jsr SYS_WRITE
        php
        lda fd
        jsr SYS_CLOSE
        plp
        bcs @err
        lda #0
        sta dirty
        lda #<m_saved
        ldx #>m_saved
        jmp set_msg
@err:   lda #<m_err
        ldx #>m_err
        jmp set_msg

; ---------------------------------------------------------------------
; editing
; insert: key at cur
insert: lda tlen+1
        cmp #>TEXTMAX
        bcc @ok
        lda #<m_full
        ldx #>m_full
        jmp set_msg
@ok:    ; move text[cur..tlen) up by one, from the end
        jsr ptr_end         ; p = text + tlen
@mv:    lda p
        cmp q
        bne @m
        lda p+1
        cmp q+1
        beq @put
@m:     ldy #0
        lda p
        bne @d
        dec p+1
@d:     dec p
        lda (p),y
        iny
        sta (p),y
        jmp @mv
@put:   ldy #0
        lda key
        sta (q),y
        inc tlen
        bne @t
        inc tlen+1
@t:     jsr cur_inc
        lda #1
        sta dirty
        jsr calc_col
        lda cx
        sta want
        rts

; delete: remove the char at cur
delete: jsr ptr_cur         ; q = text + cur
        jsr ptr_end         ; p = text + tlen
        lda p
        bne @a
        dec p+1
@a:     dec p               ; p = last char
        ldy #0
@l:     lda q
        cmp p
        lda q+1
        sbc p+1
        bcs @done
        iny
        lda (q),y
        dey
        sta (q),y
        inc q
        bne @l
        inc q+1
        jmp @l
@done:  lda tlen
        bne @t
        dec tlen+1
@t:     dec tlen
        lda #1
        sta dirty
        rts

; kill_line: delete the line the cursor is on (including its newline)
kill_line:
        jsr line_start_cur
@l:     lda cur
        cmp tlen
        bne @n
        lda cur+1
        cmp tlen+1
        beq @r
@n:     jsr ptr_cur
        ldy #0
        lda (q),y
        pha
        jsr delete
        pla
        cmp #K_RET
        bne @l
@r:     lda #0
        sta want
        rts

; ---------------------------------------------------------------------
; cursor movement
cur_inc:
        lda cur
        cmp tlen
        bne @i
        lda cur+1
        cmp tlen+1
        beq @r
@i:     inc cur
        bne @r
        inc cur+1
@r:     rts

cur_dec:
        lda cur
        ora cur+1
        beq @r
        lda cur
        bne @d
        dec cur+1
@d:     dec cur
@r:     rts

; char_before: A = text[cur-1] (Z set if cur = 0, A = 0)
char_at_cur:
        jsr ptr_cur
        lda cur
        cmp tlen
        bne @g
        lda cur+1
        cmp tlen+1
        bne @g
        lda #0
        rts
@g:     ldy #0
        lda (q),y
        rts

line_start_cur:
@l:     lda cur
        ora cur+1
        beq @r
        jsr cur_dec
        jsr char_at_cur
        cmp #K_RET
        bne @l
        jsr cur_inc
@r:     rts

line_end_cur:
@l:     jsr char_at_cur
        beq @r
        cmp #K_RET
        beq @r
        jsr cur_inc
        jmp @l
@r:     rts

; go to column `want` of the current line (or its end)
to_want:
        ldx want
@l:     cpx #0
        beq @r
        jsr char_at_cur
        beq @r
        cmp #K_RET
        beq @r
        jsr cur_inc
        dex
        jmp @l
@r:     rts

move_up:
        jsr line_start_cur
        lda cur
        ora cur+1
        beq @r
        jsr cur_dec         ; end of previous line
        jsr line_start_cur
        jmp to_want
@r:     rts

move_down:
        jsr line_end_cur
        jsr char_at_cur
        beq @r
        jsr cur_inc
        jmp to_want
@r:     rts

; calc_col: cx = cur - start of its line (capped)
calc_col:
        lda cur
        pha
        lda cur+1
        pha
        jsr line_start_cur
        pla
        sta tmp+1
        pla
        sta tmp
        lda tmp
        sec
        sbc cur
        tax
        lda tmp+1
        sbc cur+1
        beq @ok
        ldx #255
@ok:    stx cx
        lda tmp
        sta cur
        lda tmp+1
        sta cur+1
        rts

; ---------------------------------------------------------------------
; screen
; fix_top: keep the cursor line inside rows 0..ROWS-1; computes cy
fix_top:
        ; if cur < top: top = start of cur's line
        lda cur
        cmp top
        lda cur+1
        sbc top+1
        bcs @below
        jsr calc_col
        lda cur
        sec
        sbc cx
        sta top
        lda cur+1
        sbc #0
        sta top+1
@below: ; cy = newlines between top and cur
        lda top
        clc
        adc #<text
        sta p
        lda top+1
        adc #>text
        sta p+1
        lda #0
        sta cy
        jsr ptr_cur
@c:     lda p
        cmp q
        bne @n
        lda p+1
        cmp q+1
        beq @d
@n:     ldy #0
        lda (p),y
        cmp #K_RET
        bne @i
        inc cy
@i:     inc p
        bne @c
        inc p+1
        jmp @c
@d:     lda cy
        cmp #ROWS
        bcc @r
        ; scroll: top = next line
        lda top
        clc
        adc #<text
        sta p
        lda top+1
        adc #>text
        sta p+1
@s:     ldy #0
        lda (p),y
        inc p
        bne @x
        inc p+1
@x:     cmp #K_RET
        bne @s
        lda p
        sec
        sbc #<text
        sta top
        lda p+1
        sbc #>text
        sta top+1
        jmp @below
@r:     rts

redraw: jsr fix_top
        jsr calc_col
        lda top
        clc
        adc #<text
        sta p
        lda top+1
        adc #>text
        sta p+1
        lda #0
        sta row
@row:   jsr out_start
        jsr out_goto
        ldx #0              ; column
@ch:    jsr at_end
        beq @eol
        ldy #0
        lda (p),y
        inc p
        bne @x
        inc p+1
@x:     cmp #K_RET
        beq @eol
        cpx #COLS
        bcs @ch             ; past the edge: skip
        cmp #9
        bne @o
        lda #' '
@o:     jsr out_ch
        inx
        jmp @ch
@eol:   lda #ESC
        jsr out_ch
        lda #'K'
        jsr out_ch
        jsr out_flush
        inc row
        lda row
        cmp #ROWS
        bne @row
        jsr status
        ; place the cursor
        jsr out_start
        lda cy
        sta row
        jsr out_goto_col
        jmp out_flush

; at_end: Z set when p reached text + tlen
at_end: lda p
        sec
        sbc #<text
        cmp tlen
        bne @r
        lda p+1
        sbc #>text
        cmp tlen+1
@r:     rts

status: jsr out_start
        lda #ROWS
        sta row
        jsr out_goto
        lda #ESC
        jsr out_ch
        lda #'R'
        jsr out_ch
        lda msg+1
        beq @def
        lda msg
        ldx msg+1
        jsr out_str
        jmp @end
@def:   lda #<s_name
        ldx #>s_name
        jsr out_str
        lda fname+1
        beq @nn
        lda fname
        ldx fname+1
        jsr out_str
        jmp @d
@nn:    lda #<s_noname
        ldx #>s_noname
        jsr out_str
@d:     lda dirty
        beq @h
        lda #<s_mod
        ldx #>s_mod
        jsr out_str
@h:     lda #<s_help
        ldx #>s_help
        jsr out_str
@end:   lda #ESC
        jsr out_ch
        lda #'r'
        jsr out_ch
        lda #ESC
        jsr out_ch
        lda #'K'
        jsr out_ch
        jmp out_flush

; output buffer helpers (one write per screen line)
out_start:
        lda #0
        sta olen
        rts
out_goto:
        lda #0
        sta cx_tmp
        jmp og
out_goto_col:
        lda cx
        cmp #COLS
        bcc @ok
        lda #COLS-1
@ok:    sta cx_tmp
og:     lda #ESC
        jsr out_ch
        lda #'='
        jsr out_ch
        lda row
        clc
        adc #32
        jsr out_ch
        lda cx_tmp
        clc
        adc #32
        jmp out_ch
out_ch: stx ox
        ldx olen
        cpx #63
        bcs @r
        sta obuf,x
        inc olen
@r:     ldx ox
        rts
out_str:
        sta q
        stx q+1
        ldy #0
@l:     lda (q),y
        beq @r
        jsr out_ch
        iny
        cpy #COLS-1
        bcc @l
@r:     rts
out_flush:
        lda #<obuf
        sta r0
        lda #>obuf
        sta r0+1
        lda olen
        sta r1
        lda #0
        sta r1+1
        lda #1
        jmp SYS_WRITE

; pointers
ptr_cur:                    ; q = text + cur
        lda cur
        clc
        adc #<text
        sta q
        lda cur+1
        adc #>text
        sta q+1
        rts
ptr_end:                    ; p = text + tlen, q = text + cur
        lda tlen
        clc
        adc #<text
        sta p
        lda tlen+1
        adc #>text
        sta p+1
        jmp ptr_cur

.segment "RODATA"
s_clear:   .byte 12, 0
s_name:    .byte " edit: ", 0
s_noname:  .byte "(new)", 0
s_mod:     .byte " *", 0
s_help:    .byte "  ^o save ^x quit", 0
m_saved:   .byte " saved", 0
m_err:     .byte " cannot save file", 0
m_noname:  .byte " no file name: run edit file", 0
m_full:    .byte " buffer full", 0
m_unsaved: .byte " unsaved changes! ^x again quits", 0

.segment "BSS"
cx_tmp: .res 1
ox:     .res 1
