; Breadbin IEC serial bus driver
;
; Talks to the drives directly through CIA2 port A instead of the KERNAL
; ROM, so disk I/O works the same under any ROM (the Commodore KERNAL, or
; the MEGA65 Open ROMs, whose CIOUT sends every byte as $00).  The bus
; protocol and its timing follow the stock KERNAL's serial routines.
;
; ieclisten: A = drive, Y = secondary ($60|ch data, $f0|ch open, $e0|ch close)
; iectalk:   A = drive, Y = secondary ($60|ch)
; iecout:    A = byte (buffered: sent on the next iecout, or with EOI by
;            iecunlisten)
; iecin:     -> A = byte; ie_st bit 6 is set once the last byte (EOI) is in
; iecunlisten, iecuntalk
; All return carry set on a bus error (ie_st: $80 no device, $03 no frame
; acknowledge, $02 read timeout).  X and Y are preserved.  ie_st keeps
; every error since the last LISTEN/TALK, and iecunlisten reports them.
.include "k.inc"
.import tod_tick

PRA      = $dd00        ; out: bit 3 ATN, 4 CLK, 5 DATA (1 = pull low)
                        ; in:  bit 6 CLK, 7 DATA (1 = released)
CIA2_ICR = $dd0d
TB_LO    = $dd06        ; CIA2 timer B, one-shot: bus timeouts
TB_HI    = $dd07
TB_CR    = $dd0f

.segment "BSS"
ie_buf:  .res 1         ; byte being sent
ie_full: .res 1         ; bit 7: ie_buf holds a byte not sent yet
ie_eoi:  .res 1         ; bit 7: send ie_buf with EOI
ie_cnt:  .res 1
ie_in:   .res 1         ; byte being received
ie_sa:   .res 1
ie_st:   .res 1

.segment "CODE"
iec_init:
        lda #$02            ; timer B must never raise an NMI
        sta CIA2_ICR
        lda #0
        sta ie_full
        sta ie_eoi
        sta ie_st
        rts

; ---- public ----
ieclisten:
        sty ie_sa
        ora #$20
        jsr ie_cmd
        bcs @r
        jsr atn_hi
        clc
@r:     rts

iectalk:
        sty ie_sa
        ora #$40
        jsr ie_cmd
        bcs @r
        ; turn the bus round: the drive becomes the talker
        sei
        jsr data_lo
        jsr atn_hi
        jsr clk_hi
@w:     jsr ie_tick
        jsr deb
        bmi @w              ; until the drive pulls CLK
        cli
        clc
@r:     rts

; ie_cmd: A = LISTEN/TALK byte, ie_sa = secondary. Both go out under ATN.
ie_cmd:
        pha
        lda #0
        sta ie_st
        pla
        jsr ie_atn
        bcs @r
        lda ie_sa
        sta ie_buf
        jmp ie_sendatn
@r:     rts

iecout:
        bit ie_full
        bmi @send
        sec
        ror ie_full
        clc
        sta ie_buf
        rts
@send:  pha
        jsr ie_send
        pla
        sta ie_buf
        rts

; iecunlisten: also fails when any byte since the LISTEN failed (ie_st
; collects the errors; iecout's own carry is easy to lose in a send loop)
iecunlisten:
        lda #$3f
        jsr unl_unt
        bcs @r
        lda ie_st
        and #$83
        cmp #1              ; carry set if an error bit is set
@r:     rts
iecuntalk:
        sei
        jsr clk_lo
        jsr atn_lo
        lda #$5f
unl_unt:
        jsr ie_atn
        php
        jsr ie_release
        plp
        cli
        rts

iecin:
        txa
        pha
        sei
        lda #0
        sta ie_cnt
        jsr clk_hi
@rdy:   jsr ie_tick
        jsr deb
        bpl @rdy            ; until the talker releases CLK (ready to send)
@eoi:   lda #0
        sta TB_LO
        lda #1              ; 256 us: longer means the talker signals EOI
        sta TB_HI
        lda #$19
        sta TB_CR
        jsr data_hi         ; we are ready for data
@w:     lda TB_CR
        lsr a
        bcc @to
        jsr deb
        bmi @w              ; until the talker pulls CLK
        bpl @go
@to:    lda ie_cnt
        beq @ack
        pla
        tax
        lda #$02            ; still nothing after the EOI handshake
        jmp ie_err
@ack:   jsr data_lo         ; acknowledge EOI
        jsr clk_hi
        lda #$40
        ora ie_st
        sta ie_st
        inc ie_cnt
        bne @eoi
@go:    lda #8
        sta ie_cnt
@b1:    lda PRA
        cmp PRA
        bne @b1
        asl a
        bpl @b1             ; until CLK is released: the bit is valid
        ror ie_in
@b2:    lda PRA
        cmp PRA
        bne @b2
        asl a
        bmi @b2             ; until CLK is pulled again
        dec ie_cnt
        bne @b1
        jsr data_lo         ; frame acknowledge
        bit ie_st
        bvc @n
        jsr ie_release      ; last byte: let go of the bus
@n:     pla
        tax
        lda ie_in
        cli
        clc
        rts

; ---- internal ----
; ie_atn: A = command byte. Flush a pending data byte (with EOI), then
; pull ATN and send the command.
ie_atn:
        pha
        bit ie_full
        bpl @nb
        sec
        ror ie_eoi
        jsr ie_send
        lsr ie_full
        lsr ie_eoi
@nb:    pla
        sta ie_buf
        sei
        jsr data_hi
        jsr atn_lo
ie_sendatn:
        sei
        jsr clk_lo
        jsr data_hi
        jsr w1ms
; ie_send: send ie_buf (EOI if ie_eoi bit 7)
ie_send:
        sei
        jsr data_hi
        jsr deb
        bcs ie_nodev        ; nobody holds DATA: no device
        jsr clk_hi          ; we are ready to send
        bit ie_eoi
        bpl @wait
@e1:    jsr deb             ; EOI: the listener pulls DATA, then releases it
                            ; (no ie_tick in these two: the pulse is short)
        bcc @e1
@e2:    jsr deb
        bcs @e2
@wait:  jsr ie_tick
        jsr deb
        bcc @wait           ; until the listener is ready (DATA released)
        jsr clk_lo
        lda #8
        sta ie_cnt
@bit:   lda PRA
        cmp PRA
        bne @bit
        asl a
        bcc ie_frmerr       ; DATA must stay released while we send
        ror ie_buf
        bcs @one
        jsr data_lo
        bne @clk
@one:   jsr data_hi
@clk:   jsr clk_hi
        nop
        nop
        nop
        nop
        lda PRA
        and #$df            ; DATA released, CLK pulled
        ora #$10
        sta PRA
        dec ie_cnt
        bne @bit
        lda #0
        sta TB_LO
        lda #4              ; 1 ms for the frame acknowledge
        sta TB_HI
        lda #$19
        sta TB_CR
@ack:   lda TB_CR
        lsr a
        bcc ie_frmerr
        jsr deb
        bcs @ack            ; until the listener pulls DATA
        cli
        clc
        rts

ie_nodev:
        lda #$80
        bne ie_err
ie_frmerr:
        lda #$03
ie_err: ora ie_st
        sta ie_st
        cli
        jsr ie_release
        sec
        rts

; release ATN, then (after a short delay) CLK and DATA
ie_release:
        jsr atn_hi
        txa
        ldx #10
@d:     dex
        bne @d
        tax
        jsr clk_hi
        jmp data_hi

; ie_tick: the bus waits run with interrupts off, and a busy drive can keep
; them there for many jiffies. Count each jiffy that passes, as the IRQ
; would have (reading the timer flag acknowledges it, so the IRQ doesn't
; run for it). Keeps X and Y.
.export ie_tick
ie_tick:
        lda $dc0d
        lsr a               ; bit 0: CIA 1 timer A ran out
        bcc @r
        txa
        pha
        inc ticks
        bne @t
        inc ticks+1
        bne @t
        inc ticks+2
@t:     jsr tod_tick
        pla
        tax
@r:     rts

; deb: C = DATA in, N = CLK in (1 = released)
deb:    lda PRA
        cmp PRA
        bne deb
        asl a
        rts

atn_lo: lda PRA
        ora #$08
        sta PRA
        rts
atn_hi: lda PRA
        and #$f7
        sta PRA
        rts
clk_lo: lda PRA
        ora #$10
        sta PRA
        rts
clk_hi: lda PRA
        and #$ef
        sta PRA
        rts
data_lo:
        lda PRA
        ora #$20
        sta PRA
        rts
data_hi:
        lda PRA
        and #$df
        sta PRA
        rts

w1ms:   txa
        ldx #$b8
@d:     dex
        bne @d
        tax
        rts
