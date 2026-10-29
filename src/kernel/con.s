; Breadbin console: screen output and cooked keyboard input
;
; Internally everything is ASCII. Output is translated to PETSCII for the
; KERNAL screen editor (lowercase charset); keys are translated back.
.include "k.inc"

LBMAX = 79

.segment "BSS"
lb:      .res LBMAX+1   ; line buffer
lb_len:  .res 1
lb_rpos: .res 1
lb_ready: .res 1
cur_vis: .res 1         ; cursor currently drawn
cur_on:  .res 1         ; reader waiting: blink cursor
cur_t:   .res 1
cur_save: .res 1
con_busy: .res 1        ; output in progress: the IRQ must not blink
con_eof: .res 1
esc_st:  .res 1         ; escape sequence state
esc_row: .res 1
con_raw: .res 1         ; 1 = raw keys (no echo, no line editing)
raw_pid: .res 1
.export con_raw, raw_pid, to_ascii, to_petscii
dec_buf: .res 6

.segment "CODE"
con_init:
        lda #13             ; light green text
        sta $0286
        lda #$0e            ; lowercase charset
        jsr CHROUT
        lda #$08            ; lock charset (no shift+C=)
        jsr CHROUT
        lda #$93            ; clear screen
        jsr CHROUT
        lda #0
        sta lb_len
        sta lb_rpos
        sta lb_ready
        sta cur_on
        sta cur_vis
        lda #$80
        sta $028a           ; key repeat for all keys
        rts

; ---- cursor ----
cursor_hide:
        lda cur_vis
        beq @r
        tya
        pha
        ldy $d3
        lda cur_save
        sta ($d1),y
        lda #0
        sta cur_vis
        pla
        tay
@r:     rts

cursor_show:
        lda cur_vis
        bne @r
        tya
        pha
        ldy $d3
        lda ($d1),y
        sta cur_save
        eor #$80
        sta ($d1),y
        lda #1
        sta cur_vis
        pla
        tay
@r:     rts

; called from IRQ every tick
con_cursor_tick:
        lda con_busy
        bne @r
        lda cur_on
        beq @r
        dec cur_t
        bpl @r
        lda #15
        sta cur_t
        lda cur_vis
        beq @s
        jmp cursor_hide
@s:     jmp cursor_show
@r:     rts

; ---- output ----
; con_putc: print ASCII char in A. Preserves X, Y.
con_putc:
        pha
        txa
        pha
        tya
        pha
        php
        sei
        inc con_busy
        jsr cursor_hide
        plp
        tsx
        lda $0103,x
        ldx esc_st
        bne @esc
        cmp #$1b
        bne @norm
        lda #1
        sta esc_st
        bne @skip
@norm:  jsr to_petscii
        beq @skip
        jsr CHROUT
        jmp @skip
@esc:   jsr con_escape
@skip:  dec con_busy
        pla
        tay
        pla
        tax
        pla
        rts

; con_escape: A = next byte of an escape sequence, X = state
;   ESC = row+32 col+32   move the cursor
;   ESC R / ESC r          reverse video on / off
;   ESC K                  clear to the end of the line
con_escape:
        cpx #2
        bne @s3
        jmp @row
@s3:    cpx #3
        bne @s4
        jmp @col
@s4:    cpx #4
        bne @s5
        jmp @cfg
@s5:    cpx #5
        bne @s6
        jmp @cbg
@s6:    cpx #6
        bne @s0
        jmp @cbo
@s0:    ldx #0
        stx esc_st
        cmp #'='
        bne @n1
        lda #2
        sta esc_st
        rts
@n1:    cmp #'R'
        bne @n2
        lda #$12
        jmp CHROUT
@n2:    cmp #'r'
        bne @n3
        lda #$92
        jmp CHROUT
@n3:    cmp #'C'
        bne @n4
        lda #4              ; ESC C fg+32 bg+32 border+32
        sta esc_st
        rts
@n4:    cmp #'K'
        bne @r
        ldy $d3
        ldx #40
        cpy #40
        bcc @k
        ldx #80
@k:     stx tmp0
@kl:    cpy tmp0
        bcs @r
        lda #$20
        sta ($d1),y
        lda $0286
        sta ($f3),y
        iny
        bne @kl
@r:     rts
@row:   sec
        sbc #32
        sta esc_row
        lda #3
        sta esc_st
        rts
@cfg:   sec
        sbc #32
        and #15
        sta $0286
        ; recolour the whole screen
        ldy #0
@rc:    sta $d800,y
        sta $d900,y
        sta $da00,y
        sta $db00,y
        iny
        bne @rc
        lda #5
        sta esc_st
        rts
@cbg:   sec
        sbc #32
        sta $d021
        lda #6
        sta esc_st
        rts
@cbo:   sec
        sbc #32
        sta $d020
        lda #0
        sta esc_st
        rts
@col:   sec
        sbc #32
        cmp #40
        bcc @cok
        lda #39
@cok:   tay
        lda #0
        sta esc_st
        ldx esc_row
        cpx #25
        bcc @rok
        ldx #24
@rok:   clc
        jmp $fff0           ; PLOT

; con_setmode: A = 0 cooked, 1 raw (conmode syscall)
.export sys_conmode, con_release
sys_conmode:
        and #1
        sta con_raw
        ldx cur
        lda p_pid,x
        sta raw_pid
        lda #0
        sta lb_len
        sta lb_rpos
        sta lb_ready
        clc
        rts

; con_release: A = pid of an exiting process; drop raw mode it set
con_release:
        ldx con_raw
        beq @r
        cmp raw_pid
        bne @r
        lda #0
        sta con_raw
@r:     rts

; ASCII (A) -> PETSCII (A); Z set if nothing to print
to_petscii:
        cmp #$0a
        bne @1
        lda #$0d
        rts
@1:     cmp #$0c
        bne @2
        lda #$93
        rts
@2:     cmp #$08
        bne @3
        lda #$14
        rts
@3:     cmp #$09
        bne @4
        lda #$20
        rts
@4:     cmp #$20
        bcc @none
        cmp #$41
        bcc @same
        cmp #$5b
        bcc @upper
        cmp #$5f
        beq @under
        bcc @same           ; [ \ ] ^
        cmp #$61
        bcc @none           ; `
        cmp #$7b
        bcc @lower
        cmp #$7c
        beq @bar
        lda #$3f            ; { } ~ -> ?
        rts
@upper: ora #$80
        rts
@lower: and #$df
        rts
@under: lda #$a4
        rts
@bar:   lda #$dd
        rts
@same:  ora #0
        rts
@none:  lda #0
        rts

; PETSCII (A) -> ASCII (A); 0 if unmapped
to_ascii:
        cmp #$20
        bcc @none
        cmp #$41
        bcc @same
        cmp #$5b
        bcc @low
        cmp #$5f
        beq @under
        bcc @same
        cmp #$61
        bcc @none
        cmp #$7b
        bcc @up
        cmp #$dd
        beq @bar
        cmp #$c1
        bcc @none
        cmp #$db
        bcs @none
        and #$7f
        rts
@low:   ora #$20
        rts
@up:    and #$df
        rts
@under: lda #$5f
        rts
@bar:   lda #$7c
        rts
@same:  rts
@none:  lda #0
        rts

; con_puts_ax: print NUL-terminated string at A/X
con_puts_ax:
        sta p4
        stx p4+1
        ldy #0
@l:     lda (p4),y
        beq @d
        jsr con_putc
        iny
        bne @l
        inc p4+1
        bne @l
@d:     rts

; con_dec: print 16-bit unsigned A/X in decimal
con_dec:
        sta tmp0
        stx tmp1
        ldy #5
        lda #0
        sta dec_buf+5
@digit: ; divide tmp0/1 by 10, remainder in A
        lda #0
        ldx #16
@div:   asl tmp0
        rol tmp1
        rol a
        cmp #10
        bcc @n
        sbc #10
        inc tmp0
@n:     dex
        bne @div
        ora #'0'
        dey
        sta dec_buf,y
        lda tmp0
        ora tmp1
        bne @digit
        tya
        clc
        adc #<dec_buf
        ldx #>dec_buf
        bcc @p
        inx
@p:     jmp con_puts_ax

; con_hex: print A as two hex digits
con_hex:
        pha
        lsr a
        lsr a
        lsr a
        lsr a
        jsr @nib
        pla
        and #$0f
@nib:   cmp #10
        bcc @d
        adc #'a'-'0'-11
@d:     adc #'0'
        jmp con_putc

; con_write: write r1 bytes from (r0) to the screen. Returns r1 unchanged.
con_write:
        lda r0
        sta p1
        lda r0+1
        sta p1+1
        lda r1
        sta p2
        lda r1+1
        sta p2+1
        ldy #0
@l:     lda p2
        ora p2+1
        beq @d
        lda (p1),y
        jsr con_putc
        inc p1
        bne @c
        inc p1+1
@c:     lda p2
        bne @dl
        dec p2+1
@dl:    dec p2
        jmp @l
@d:     clc
        rts

; con_read: cooked read of up to r1 bytes into (r0). Blocks until a line
; is complete (or CTRL-D on an empty line = EOF). Returns r1 = count.
con_read:
        lda con_raw
        beq @wait
        jmp raw_read
@wait:  lda lb_ready
        bne @copy
        jsr GETIN
        cmp #0
        bne @key
        lda #1
        sta cur_on
        lda #CH_TICK
        jsr block_on
        jmp @wait
@key:   pha
        php
        sei
        lda #0
        sta cur_on
        jsr cursor_hide
        plp
        pla
        cmp #$0d
        beq @ret
        cmp #$14
        beq @del
        cmp #$04
        beq @eof
        jsr to_ascii
        beq @wait
        ldx lb_len
        cpx #LBMAX
        bcs @wait
        sta lb,x
        inc lb_len
        jsr con_putc
        jmp @wait
@del:   lda lb_len
        beq @wait
        dec lb_len
        lda #$08
        jsr con_putc
        jmp @wait
@eof:   lda lb_len
        bne @wait
        lda #0
        sta r1
        sta r1+1
        clc
        rts
@ret:   lda #10
        ldx lb_len
        sta lb,x
        inc lb_len
        jsr con_putc
        lda #1
        sta lb_ready
@copy:  ; copy min(r1, lb_len - lb_rpos) bytes
        ldy #0
        ldx lb_rpos
@cl:    cpx lb_len
        bcs @done
        lda r1+1
        bne @more
        cpy r1
        bcs @done
@more:  lda lb,x
        sta (r0),y
        inx
        iny
        bne @cl
@done:  stx lb_rpos
        sty r1
        lda #0
        sta r1+1
        cpx lb_len
        bcc @r
        lda #0
        sta lb_len
        sta lb_rpos
        sta lb_ready
@r:     clc
        rts

; raw_read: one key, no echo. Cursor keys come as control codes:
;   up ^P($10) down ^N($0e) left ^B($02) right ^F($06) home ^A($01)
;   clr ^L($0c) del ^H($08) return $0a; F1-F8 as $85-$8c; ctrl-letters $01-$1a
raw_read:
@w:     jsr GETIN
        cmp #0
        bne @k
        lda #1
        sta cur_on
        lda #CH_TICK
        jsr block_on
        jmp @w
@k:     pha
        php
        sei
        lda #0
        sta cur_on
        jsr cursor_hide
        plp
        pla
        ldx #rawmap_n-1
@m:     cmp rawmap_in,x
        beq @hit
        dex
        bpl @m
        cmp #$85
        bcc @c
        cmp #$8d
        bcc @store
@c:     cmp #$1b
        bcc @store
        jsr to_ascii
        beq @w
        jmp @store
@hit:   lda rawmap_out,x
@store: ldy #0
        sta (r0),y
        lda #1
        sta r1
        lda #0
        sta r1+1
        clc
        rts

.segment "RODATA"
rawmap_in:  .byte $0d, $14, $91, $11, $9d, $1d, $13, $93
rawmap_out: .byte $0a, $08, $10, $0e, $02, $06, $01, $0c
rawmap_n = * - rawmap_out
