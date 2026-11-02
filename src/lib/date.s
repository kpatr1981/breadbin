; date: seconds since 1970 (local time, as c64fs and SYS_CLOCK keep them)
; <-> calendar, and printing them. Linked only into programs that use it.
;
;   ep2cal      dt_ep (4 bytes) -> dt_year (2), dt_mon, dt_day, dt_h, dt_m, dt_s
;   cal2ep      the reverse (the fields must be valid; see month_len)
;   month_len   A = month (1-12), dt_year -> A = its days
;   print_date  A = 0: "YY-MM-DD hh:mm" (14 characters), A = 1:
;               "YYYY-MM-DD hh:mm:ss" (19), from the fields
;
; Years 1970-2106 (where 32 bits end). Everything is in BSS, no zero page.
.include "../../include/breadbin.inc"
.export ep2cal, cal2ep, month_len, print_date
.export dt_ep, dt_year, dt_mon, dt_day, dt_h, dt_m, dt_s

.segment "CODE"
ep2cal: ldx #3
@c:     lda dt_ep,x
        sta q,x
        dex
        bpl @c
        lda #60
        jsr div8
        sta dt_s
        lda #60
        jsr div8
        sta dt_m
        lda #24
        jsr div8
        sta dt_h
        ; q = days since 1970-01-01 (16 bits)
        lda #<1970
        sta dt_year
        lda #>1970
        sta dt_year+1
@y:     lda dt_year
        ldx dt_year+1
        jsr year_len        ; A = low byte, the high byte is 1
        sta t
        lda q
        cmp t
        lda q+1
        sbc #1
        bcc @m              ; fewer days left than this year has
        lda q
        sbc t
        sta q
        lda q+1
        sbc #1
        sta q+1
        inc dt_year
        bne @y
        inc dt_year+1
        bne @y
@m:     lda #1
        sta dt_mon
@ml:    lda dt_mon
        jsr month_len
        sta t
        lda q+1
        bne @mn             ; 256 days or more: past any month
        lda q
        cmp t
        bcc @d
@mn:    lda q
        sec
        sbc t
        sta q
        bcs @mi
        dec q+1
@mi:    inc dt_mon
        bne @ml
@d:     ldx q
        inx
        stx dt_day
        rts

cal2ep: lda #0
        ldx #3
@z:     sta q,x
        dex
        bpl @z
        lda #<1970
        sta yr
        lda #>1970
        sta yr+1
@y:     lda yr              ; whole years before dt_year
        cmp dt_year
        lda yr+1
        sbc dt_year+1
        bcs @m
        lda yr
        ldx yr+1
        jsr year_len
        clc
        adc q
        sta q
        txa
        adc q+1
        sta q+1
        inc yr
        bne @y
        inc yr+1
        bne @y
@m:     lda #1              ; whole months before dt_mon
        sta t
@ml:    lda t
        cmp dt_mon
        bcs @d
        jsr month_len
        clc
        adc q
        sta q
        bcc @mi
        inc q+1
@mi:    inc t
        bne @ml
@d:     ldx dt_day          ; the days before dt_day
        dex
        txa
        jsr add8
        lda #24
        jsr mul8
        lda dt_h
        jsr add8
        lda #60
        jsr mul8
        lda dt_m
        jsr add8
        lda #60
        jsr mul8
        lda dt_s
        jsr add8
        ldx #3
@o:     lda q,x
        sta dt_ep,x
        dex
        bpl @o
        rts

; year_len: A/X = year -> A/X = 365 or 366
year_len:
        jsr leap
        lda #<365
        adc #0              ; carry = leap year
        ldx #>365
        rts

; leap: A/X = year -> carry set in a leap year (every 4th, but not 2100)
leap:   sta lt
        and #3
        bne @no
        lda lt
        cmp #<2100
        bne @yes
        cpx #>2100
        beq @no
@yes:   sec
        rts
@no:    clc
        rts

month_len:
        tax
        lda mdays-1,x
        cpx #2
        bne @r
        pha
        lda dt_year
        ldx dt_year+1
        jsr leap
        pla
        adc #0
@r:     rts

; div8: q /= A (A < 128); A = the remainder
div8:   sta dv
        lda #0
        ldx #32
@l:     asl q
        rol q+1
        rol q+2
        rol q+3
        rol a
        cmp dv
        bcc @n
        sbc dv
        inc q
@n:     dex
        bne @l
        rts

; mul8: q *= A (32 bits, overflow dropped)
mul8:   sta dv
        lda #0
        ldx #3
@z:     sta r,x
        dex
        bpl @z
        ldy #8
@l:     asl r
        rol r+1
        rol r+2
        rol r+3
        asl dv
        bcc @n
        clc
        ldx #0
@a:     lda r,x
        adc q,x
        sta r,x
        inx
        txa
        eor #4
        bne @a
@n:     dey
        bne @l
        ldx #3
@c:     lda r,x
        sta q,x
        dex
        bpl @c
        rts

; add8: q += A
add8:   clc
        adc q
        sta q
        bcc @r
        inc q+1
        bne @r
        inc q+2
        bne @r
        inc q+3
@r:     rts

print_date:
        sta t
        lda dt_year         ; yr = year % 100, X = year / 100
        sta yr
        lda dt_year+1
        sta yr+1
        ldx #0
@c:     lda yr
        sec
        sbc #100
        tay
        lda yr+1
        sbc #0
        bcc @e
        sta yr+1
        sty yr
        inx
        bne @c
@e:     lda t
        beq @short
        txa
        jsr two
@short: lda yr
        jsr two
        lda #'-'
        jsr SYS_PUTC
        lda dt_mon
        jsr two
        lda #'-'
        jsr SYS_PUTC
        lda dt_day
        jsr two
        lda #' '
        jsr SYS_PUTC
        lda dt_h
        jsr two
        lda #':'
        jsr SYS_PUTC
        lda dt_m
        jsr two
        lda t
        beq @r
        lda #':'
        jsr SYS_PUTC
        lda dt_s
        jmp two
@r:     rts

; two: A = 0-99 -> two digits
two:    ldx #'0'
        sec
@t:     cmp #10
        bcc @o
        sbc #10
        inx
        bne @t
@o:     pha
        txa
        jsr SYS_PUTC
        pla
        ora #'0'
        jmp SYS_PUTC

.segment "RODATA"
mdays:  .byte 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31

.segment "BSS"
dt_ep:   .res 4
dt_year: .res 2
dt_mon:  .res 1
dt_day:  .res 1
dt_h:    .res 1
dt_m:    .res 1
dt_s:    .res 1
q:       .res 4
r:       .res 4
dv:      .res 1
t:       .res 1
lt:      .res 1
yr:      .res 2
