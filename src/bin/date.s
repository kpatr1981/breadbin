; date [YYYY-MM-DD] [hh:mm[:ss]]: show or set the date and time (the
; kernel's clock, SYS_CLOCK). A time alone keeps the date; a date alone
; keeps the time. Only root may set it.
.include "../../include/breadbin.inc"
.import newline, argn, eprint, perr
.import ep2cal, cal2ep, month_len, print_date
.import dt_ep, dt_year, dt_mon, dt_day, dt_h, dt_m, dt_s
.importzp lp1
idx = $23
val = $24               ; 2 bytes
.segment "CODE"
        jsr get
        lda #1
        sta idx
@arg:   lda idx
        jsr argn
        bcs @set
        sta lp1
        stx lp1+1
        ldy #4              ; YYYY- or hh:
        lda (lp1),y
        cmp #'-'
        beq @date
        ldy #0
        jsr time
        bcs usage
        bcc @next
@date:  ldy #0
        jsr date
        bcs usage
@next:  inc idx
        lda idx
        cmp #3
        bcc @arg
@set:   lda idx
        cmp #2
        bcc show            ; no arguments
        jsr cal2ep
        lda #<dt_ep
        sta r0
        lda #>dt_ep
        sta r0+1
        lda #1
        jsr SYS_CLOCK
        bcc @ok
        ldx #0
        ldy #0
        jsr perr
        lda #1
        jmp SYS_EXIT
@ok:    jsr get
show:   lda #1
        jsr print_date
        jmp newline

usage:  lda #<s_usage
        ldx #>s_usage
        jsr eprint
        lda #2
        jmp SYS_EXIT

; get: the clock -> the fields
get:    lda #<dt_ep
        sta r0
        lda #>dt_ep
        sta r0+1
        lda #0
        jsr SYS_CLOCK
        jmp ep2cal

; date: YYYY-MM-DD at (lp1),y -> dt_year, dt_mon, dt_day; carry set if bad
date:   jsr num
        bcs @r
        lda val
        cmp #<1970
        lda val+1
        sbc #>1970
        bcc @bad
        lda val
        cmp #<2106
        lda val+1
        sbc #>2106
        bcs @bad
        lda val
        sta dt_year
        lda val+1
        sta dt_year+1
        lda #'-'
        jsr sep
        bcs @r
        jsr num
        bcs @r
        lda val+1
        bne @bad
        lda val
        beq @bad
        cmp #13
        bcs @bad
        sta dt_mon
        lda #'-'
        jsr sep
        bcs @r
        jsr num
        bcs @r
        lda val+1
        bne @bad
        lda val
        beq @bad
        sta dt_day
        sty ys
        lda dt_mon
        jsr month_len
        ldy ys
        cmp dt_day
        bcc @bad
        jmp end
@bad:   sec
@r:     rts

; time: hh:mm[:ss] at (lp1),y -> dt_h, dt_m, dt_s; carry set if bad
time:   jsr num
        bcs @r
        lda #24
        jsr small
        bcs @r
        sta dt_h
        lda #':'
        jsr sep
        bcs @r
        jsr num
        bcs @r
        lda #60
        jsr small
        bcs @r
        sta dt_m
        lda #0
        sta dt_s
        lda (lp1),y
        beq @ok
        lda #':'
        jsr sep
        bcs @r
        jsr num
        bcs @r
        lda #60
        jsr small
        bcs @r
        sta dt_s
@ok:    jmp end
@r:     rts

; small: val < A? -> A = val, carry clear; else carry set
small:  sta lim
        lda val+1
        bne @no
        lda val
        cmp lim
        rts
@no:    sec
        rts

; num: decimal digits at (lp1),y -> val; carry set if none
num:    lda #0
        sta val
        sta val+1
        tax                 ; digits seen
@l:     lda (lp1),y
        sec
        sbc #'0'
        cmp #10
        bcs @e
        pha
        lda val             ; val = val * 10 + digit
        asl a
        sta tmp
        lda val+1
        rol a
        sta tmp+1
        asl tmp
        rol tmp+1
        asl tmp
        rol tmp+1           ; tmp = val * 8
        lda val
        asl a
        sta val
        rol val+1           ; val * 2 (high byte: carry only from the low)
        lda val
        clc
        adc tmp
        sta val
        lda val+1
        adc tmp+1
        sta val+1
        pla
        clc
        adc val
        sta val
        bcc @n
        inc val+1
@n:     iny
        inx
        cpx #5
        bcc @l
@e:     clc             ; carry set if there were no digits
        txa
        bne @r
        sec
@r:     rts

; sep: the character at (lp1),y must be A; skip it
sep:    cmp (lp1),y
        bne @b
        iny
        clc
        rts
@b:     sec
        rts

; end: nothing may follow
end:    lda (lp1),y
        cmp #1
        rts

.segment "RODATA"
s_usage: .byte "usage: date [yyyy-mm-dd] [hh:mm[:ss]]", 10, 0
.segment "BSS"
tmp: .res 2
ys:  .res 1
lim: .res 1
