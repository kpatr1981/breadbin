; Breadbin fast read: code that runs in the 1541
;
; blk.s uploads it to drive memory $0500 (buffer 2) with M-W and starts it
; with "M-E" lo hi track sector (the command stays in the drive's command
; buffer at $0200, so the code reads track and sector from $0205/$0206).
;
; 1. CLK low: the code is running. It reads the sector into buffer 3
;    ($0600) with the controller's job queue.
; 2. DATA = status (low = error), then CLK released: done.
; 3. If the read worked, the C64 clocks the 256 bytes out with CLK, one bit
;    per edge, most significant first: the drive puts each bit on DATA
;    (released = 1) after it sees the edge. One more CLK pulse from the C64
;    ends it (it has read the last bit; or, on an error, has seen the
;    status): the drive lets go of DATA only then.
; ATN is never used, so other drives on the bus stay idle.
.include "k.inc"
.export drv_code, drv_size, DRV_ADDR

DRV_ADDR = $0500
VIA1     = $1800        ; PB1 DATA out, PB3 CLK out (1 = pull low),
                        ; PB2 CLK in (1 = low)
JOB3     = $0003        ; job code for buffer 3 ($80 = read; result 1 = ok)
HDR3     = $000c        ; track, sector for buffer 3
BUF3     = $0600

.segment "RODATA"
drv_code:
.org DRV_ADDR
        lda #$08            ; CLK low: running
        sta VIA1
        lda $0205
        sta HDR3
        lda $0206
        sta HDR3+1
        lda #$80
        sta JOB3
        cli
@job:   lda JOB3
        bmi @job
        sei
        cmp #2
        bcs @err
        lda #$08            ; DATA released (ok) ...
        sta VIA1
        lda #$00            ; ... then CLK too: done (DATA settles first:
        sta VIA1            ; the C64 reads it as soon as it sees CLK)
        ldy #0
@byte:  lda BUF3,y
        eor #$ff            ; a 0 bit pulls DATA low
        sta ib
        lda #4
        sta cnt
@pair:  lda #0              ; next bit -> X = $02 (pull) or $00
        asl ib
        rol a
        asl a
        tax
@w0:    lda VIA1            ; the C64 pulls CLK
        and #$04
        beq @w0
        stx VIA1
        lda #0
        asl ib
        rol a
        asl a
        tax
@w1:    lda VIA1            ; ... and releases it
        and #$04
        bne @w1
        stx VIA1
        dec cnt
        bne @pair
        iny
        bne @byte
        beq @end
@err:   lda #$0a            ; DATA low (error), CLK still low
        sta VIA1
        lda #$02            ; CLK released: done
        sta VIA1
@end:   lda VIA1            ; the C64 pulls CLK once more: it has read the
        and #$04            ; last bit (or seen the status), so DATA may go
        beq @end
        lda #0              ; let go of the bus
        sta VIA1
        cli
        rts
ib:     .byte 0
cnt:    .byte 0
.reloc
drv_size = * - drv_code
