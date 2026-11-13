; memhog [rounds]: takes 41 pages, fills them with a pattern of its own
; (from its pid), then sleeps 10 s and checks the pattern, rounds (3)
; times; prints "ok" or "bad".
; A few of them at once need more than the pool: the swap test.
.include "../../include/breadbin.inc"
.import print, newline, argn, parse_dec
SIZE = 40*256
p    = $23              ; 2
pid  = $25
n    = $26
bad  = $27
.segment "CODE"
        jsr SYS_GETPID
        sta pid
        lda #0
        sta bad
        jsr fill
        lda #3
        sta n
        lda #1
        jsr argn
        bcs @r
        jsr parse_dec
        bcs @r
        sta n
@r:     lda #<600           ; 10 s: the others run meanwhile
        ldx #>600
        jsr SYS_SLEEP
        jsr check
        dec n
        bne @r
        lda bad
        bne @bad
        lda #<s_ok
        ldx #>s_ok
        jsr print
        jsr newline
        lda #0
        jmp SYS_EXIT
@bad:   lda #<s_bad
        ldx #>s_bad
        jsr print
        jsr newline
        lda #1
        jmp SYS_EXIT

; the byte at buf+i is lo(i) + hi(i) + pid
start:  lda #<buf
        sta p
        lda #>buf
        sta p+1
        ldx #>SIZE
        ldy #0
        rts
fill:   jsr start
@l:     tya
        clc
        adc p+1
        adc pid
        sta (p),y
        iny
        bne @l
        inc p+1
        dex
        bne @l
        rts
check:  jsr start
@l:     tya
        clc
        adc p+1
        adc pid
        cmp (p),y
        beq @ok
        inc bad
@ok:    iny
        bne @l
        inc p+1
        dex
        bne @l
        rts

.segment "RODATA"
s_ok:   .byte "ok", 0
s_bad:  .byte "bad", 0
.segment "BSS"
buf:    .res SIZE
