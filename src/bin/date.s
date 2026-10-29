; date [hh:mm[:ss]]: show or set the time of day (CIA 1 TOD clock)
.include "../../include/c64os.inc"
.import print, putc, newline, argn
.importzp lp1
TOD_10 = $dc08
TOD_S  = $dc09
TOD_M  = $dc0a
TOD_H  = $dc0b
.segment "CODE"
        lda #1
        jsr argn
        bcs show
        sta lp1
        stx lp1+1
        ldy #0
        jsr bcd2
        bcc *+5
        jmp usage
        sta hh
        jsr colon
        bcc *+5
        jmp usage
        jsr bcd2
        bcc *+5
        jmp usage
        sta mm
        lda #0
        sta ss
        lda (lp1),y
        beq @set
        jsr colon
        bcc *+5
        jmp usage
        jsr bcd2
        bcc *+5
        jmp usage
        sta ss
@set:   ; 24h -> 12h + PM bit
        lda hh
        sed
        cmp #$12
        bcc @am
        beq @pm12
        sec
        sbc #$12
@pm12:  ora #$80
        jmp @h
@am:    cmp #0
        bne @h
        lda #$12            ; 00 -> 12 am
@h:     cld
        sta TOD_H           ; writing hours stops the clock
        lda mm
        sta TOD_M
        lda ss
        sta TOD_S
        lda #0
        sta TOD_10          ; writing tenths starts it
show:   lda TOD_H           ; reading hours latches the clock
        sta hh
        lda TOD_M
        sta mm
        lda TOD_S
        sta ss
        lda TOD_10          ; unlatch
        ; 12h + PM -> 24h
        lda hh
        and #$7f
        cmp #$12
        bne @n12
        lda #0
@n12:   bit hh
        bpl @am
        sed
        clc
        adc #$12
        cld
@am:    jsr hex2
        lda #':'
        jsr putc
        lda mm
        jsr hex2
        lda #':'
        jsr putc
        lda ss
        jsr hex2
        jmp newline
usage:  lda #<s_usage
        ldx #>s_usage
        jsr print
        lda #1
        jmp SYS_EXIT
hex2:   pha
        lsr a
        lsr a
        lsr a
        lsr a
        ora #'0'
        jsr putc
        pla
        and #$0f
        ora #'0'
        jmp putc
; bcd2: two digits at (lp1),y -> A (BCD), y += 2
bcd2:   lda (lp1),y
        jsr dig
        bcs @r
        asl a
        asl a
        asl a
        asl a
        sta tmp
        iny
        lda (lp1),y
        jsr dig
        bcs @r
        ora tmp
        iny
        clc
@r:     rts
dig:    sec
        sbc #'0'
        cmp #10
        rts
colon:  lda (lp1),y
        cmp #':'
        bne @b
        iny
        clc
        rts
@b:     sec
        rts
.segment "RODATA"
s_usage: .byte "usage: date [hh:mm[:ss]]", 10, 0
.segment "BSS"
hh:  .res 1
mm:  .res 1
ss:  .res 1
tmp: .res 1
