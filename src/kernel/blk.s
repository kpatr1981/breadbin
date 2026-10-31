; Breadbin block devices and buffer cache
;
; dev 0: 1541 on IEC device 8, raw 256-byte sectors via "U1"/"U2"/"B-P"
;        (through Breadbin's own bus driver, iec.s, not the KERNAL)
; dev 1: RAM disk in an REU (block b = REU bank b>>8, page b&$ff) or, with
;        no REU, a GeoRAM (block b = 16 KB block b>>6, page b&63)
; dev 2-4: drives 9-11 (mounted with mount()), same sector commands
; With no drive 8 but a disk image preloaded into the REU (an emulator's
; .reu file: block b at offset b*256), dev 0 is that image and there is no
; RAM disk.
; Cache is write-back: bdirty marks a buffer changed, and it reaches its
; device when it is evicted, on bflush_all (close of a written file, sync,
; umount), or by bflush_due once it has been changed for 2 seconds.
.include "k.inc"
.import drv_code, drv_size, DRV_ADDR, ie_tick


REU_STATUS = $df00
REU_CMD    = $df01
REU_C64LO  = $df02
REU_C64HI  = $df03
REU_LO     = $df04
REU_HI     = $df05
REU_BANK   = $df06
REU_LENLO  = $df07
REU_LENHI  = $df08
REU_CTRL   = $df0a
GEO_WIN    = $de00      ; GeoRAM: 256-byte window onto the selected page
GEO_PAGE   = $dffe      ; page within the 16 KB block (0-63), write only
GEO_BLK    = $dfff      ; 16 KB block, write only

.segment "ZEROPAGE"
bp:      .res 2         ; pointer to the buffer returned by bread
.exportzp bp

.segment "BSS"
bufs:    .res NBUF*256
b_valid: .res NBUF
b_dev:   .res NBUF
b_lo:    .res NBUF
b_hi:    .res NBUF
b_age:   .res NBUF      ; lookup clock at the last use (16-bit)
b_ageh:  .res NBUF
b_dirty: .res NBUF      ; changed since it was read or written
dirty_on: .res 1        ; some buffer is changed, since jiffy dirty_t
dirty_t: .res 2
fl_x:    .res 1
fl_err:  .res 1
b_clock: .res 2
lru_age: .res 2         ; cache_victim scratch: callers keep tmp1-tmp3 across bread
lru_cur: .res 1
b_idx:   .res 1
rq_dev:  .res 1
rq_lo:   .res 1
rq_hi:   .res 1
trk:     .res 1
sct:     .res 1
reu_banks: .res 1      ; RAM expansion size in 64 KB units
ram_type:  .res 1      ; 0 none, 1 REU, 2 GeoRAM
dev_present: .res NDEV
dev_type: .res NDEV
cur_drive: .res 1
cmdbuf:  .res 40
cmdlen:  .res 1
reu_tmp: .res 1
reu_save = bufs         ; byte 0 of each bank (or GeoRAM block), kept across
                        ; detection: the cache is still unused at boot
root_reu: .res 1        ; 1: dev 0 lives in the REU
rd_banks: .res 1        ; REU banks for the /tmp RAM disk
dc_on:   .res 1         ; drive 8's blocks are copied into the REU ...
dc_base: .res 1         ; ... from this bank on (683 blocks: 3 banks)
dc_have: .res 86        ; one bit per block: it is in the REU copy
dc_hi:   .res 1
DC_BANKS = 3
fl_up:   .res NDEV      ; fast read: the drive code is in the drive
fl_bad:  .res NDEV      ; fast read: this drive can't (use the slow way)
cw_want: .res 1
cw_n:    .res 2
cw_t:    .res 1
fr_on:   .res 1
fr_off:  .res 1
fr_val:  .res 1
up_off:  .res 1
up_n:    .res 1

.export bwrite, bdirty, buf_idx_ptr, bflush_due, sys_sync, rd_banks

.segment "RODATA"
; first linear block of each track (tracks 1..36), 16-bit
trk_lo: .lobytes 0,21,42,63,84,105,126,147,168,189,210,231,252,273,294,315,336,357,376,395,414,433,452,471,490,508,526,544,562,580,598,615,632,649,666,683
trk_hi: .hibytes 0,21,42,63,84,105,126,147,168,189,210,231,252,273,294,315,336,357,376,395,414,433,452,471,490,508,526,544,562,580,598,615,632,649,666,683
dev_drive: .byte 8, 0, 9, 10, 11

.segment "CODE"
blk_init:
        ldx #NBUF-1
        lda #0
@l:     sta b_valid,x
        dex
        bpl @l
        jsr iec_init
        lda #0
        sta root_reu
        lda #1
        sta dev_present
        jsr reu_detect
        lda reu_banks
        sta rd_banks
        ldx #0
        jsr iec_open
        bcc @drv
        lda reu_banks       ; no drive 8: boot from the REU instead
        beq @r
        lda #1
        sta root_reu
        lda #0
        sta dev_present+1
@r:     rts
@drv:   lda reu_banks       ; 4+ banks: the top 3 keep a copy of drive 8
        cmp #DC_BANKS+1
        bcc @r
        sec
        sbc #DC_BANKS
        sta rd_banks
        sta dc_base
        inc dc_on
        rts

; is_reu: A = dev -> Z set if its blocks live in the REU
is_reu: cmp #1
        beq @r
        cmp #0
        bne @r
        lda root_reu
        eor #1
@r:     rts

; iec_open: X = dev. Open the drive's command channel (15, initialising
; the disk) and data channel 2 with a drive buffer. Carry set (A = ENODEV)
; if the drive is not there.
iec_open:
        stx tmp2
        lda dev_drive,x
        ldy #$f0+15
        jsr ieclisten
        bcs @nodev
        lda #'I'
        jsr iecout
        lda #'0'
        jsr iecout
        jsr iecunlisten
        bcs @nodev
        ldx tmp2
        lda #0
        sta fl_up,x
        sta fl_bad,x
        lda dev_drive,x
        ldy #$f0+2
        jsr ieclisten
        bcs @nodev
        lda #'#'            ; channel 2 gets buffer 1: buffers 2 and 3 stay
        jsr iecout          ; free for the fast read code
        lda #'1'
        jsr iecout
        jsr iecunlisten
        bcs @nodev
        lda tmp2
        jsr cur_dev_set
        jsr cmd_status
        bcc @ok
        ldx tmp2            ; buffer 1 is taken: any buffer, and no fast reads
        inc fl_bad,x
        lda dev_drive,x
        ldy #$f0+2
        jsr ieclisten
        bcs @nodev
        lda #'#'
        jsr iecout
        jsr iecunlisten
        bcs @nodev
@ok:    ldx tmp2
        clc
        rts
@nodev: ldx tmp2
        jsr iec_close
        lda #ENODEV
        sec
        rts

; iec_close: X = dev
iec_close:
        stx tmp2
        lda dev_drive,x
        ldy #$e0+2
        jsr ieclisten
        bcs @c
        jsr iecunlisten
@c:     ldx tmp2
        lda dev_drive,x
        ldy #$e0+15
        jsr ieclisten
        bcs @r
        jsr iecunlisten
@r:     ldx tmp2
        rts

; cur_dev_set: A = dev -> the drive used by the IEC routines below
cur_dev_set:
        tax
        lda dev_drive,x
        sta cur_drive
        rts

; iec_command: A = dev, cmdbuf/cmdlen = command. Sends it and reads the
; drive status; carry clear if it reports 00 or 01.
iec_command:
        jsr cur_dev_set
        jsr cmd_send
        bcs @r
        jmp cmd_status
@r:     rts
.export cmdbuf, cmdlen, iec_status

; iec_status: A = dev -> carry clear if the drive's status is 00 or 01
iec_status:
        jsr cur_dev_set
        jmp cmd_status

; ts_block: A = track, X = sector -> X/Y = linear block number
ts_block:
        stx tmp0
        tay
        dey
        lda trk_lo,y
        clc
        adc tmp0
        tax
        lda trk_hi,y
        adc #0
        tay
        rts

; buf_idx_ptr: X = buffer index -> bp. Preserves X.
buf_idx_ptr:
        lda #<bufs
        sta bp
        txa
        clc
        adc #>bufs
        sta bp+1
        rts

; bread: A = dev, X/Y = block lo/hi -> X = buffer index, bp = data.
; carry set on I/O error (A = EIO).
bread:
        jsr cache_find
        bcs @miss
        rts
@miss:  jsr cache_victim
        lda rq_dev
        jsr is_reu
        beq @reu
        lda rq_dev
        bne @iec
        jsr dc_get          ; drive 8: from its copy in the REU?
        bcc @chk
@iec:   lda rq_dev
        jsr cur_dev_set
        jsr iec_read
        bcs @chk
        lda rq_dev
        bne @chk
        jsr dc_put          ; (clears carry)
        jmp @chk
@reu:   jsr reu_read
@chk:   ldx b_idx
        bcc @ok
        lda #0
        sta b_valid,x
        lda #EIO
        rts
@ok:    lda #1
        sta b_valid,x
        jsr buf_idx_ptr
        clc
        rts

; bget_buf: like bread, but the block's old contents are not needed:
; returns a zeroed buffer assigned to that block (not written yet).
bget_buf:
        jsr cache_find
        bcc @have
        jsr cache_victim
        ldx b_idx
        lda #1
        sta b_valid,x
        jsr buf_idx_ptr
@have:  ldy #0
        tya
@z:     sta (bp),y
        iny
        bne @z
        clc
        rts

; bwrite: X = buffer index. Write it to its device now. Carry set (A = EIO)
; on an I/O error; either way the buffer counts as clean afterwards.
bwrite:
        stx b_idx
        lda b_dev,x
        sta rq_dev
        lda b_lo,x
        sta rq_lo
        lda b_hi,x
        sta rq_hi
        jsr buf_idx_ptr
        lda rq_dev
        jsr is_reu
        beq @reu
        lda rq_dev
        jsr cur_dev_set
        jsr iec_write
        bcs @r
        lda rq_dev
        bne @r
        jsr dc_put          ; keep drive 8's REU copy current
        jmp @r
@reu:   jsr reu_write
@r:     ldx b_idx
        lda #0
        sta b_dirty,x
        bcc @ok
        lda #EIO
@ok:    rts

; bdirty: X = buffer index. Mark it changed (written back later).
bdirty:
        lda b_dirty,x
        bne @r
        lda #1
        sta b_dirty,x
        lda dirty_on
        bne @r
        inc dirty_on
        lda ticks
        sta dirty_t
        lda ticks+1
        sta dirty_t+1
@r:     clc
        rts

; bflush_all: write every changed buffer back. Carry set (A = EIO) if one
; failed: that block is lost (it is dropped, so a bad disk can't make every
; later flush retry it).
bflush_all:
        lda #0
        sta fl_err
        ldx #NBUF-1
@l:     lda b_dirty,x
        beq @n
        stx fl_x
        jsr bwrite
        ldx fl_x
        bcc @n
        sta fl_err
        lda #0
        sta b_valid,x
@n:     dex
        bpl @l
        lda #0
        sta dirty_on
        lda fl_err
        beq @ok
        sec
        rts
@ok:    clc
        rts

; sync(): write back every changed block
sys_sync = bflush_all

; bflush_due: on every return from a system call. Write back once a block
; has been changed for 2 seconds.
bflush_due:
        lda dirty_on
        beq @r
        lda ticks
        sec
        sbc dirty_t
        tax
        lda ticks+1
        sbc dirty_t+1
        bne @go
        cpx #120
        bcc @r
@go:    jmp bflush_all
@r:     rts

; dc_get: drive 8 block rq_* -> bp from the REU copy; carry set if it
; isn't there. dc_put: copy bp there (and remember it); carry clear.
dc_get: jsr dc_bit
        bcs @r
        and dc_have,y
        beq @no
        jsr dc_to
        jsr reu_read
        jmp dc_back
@no:    sec
@r:     rts

dc_put: jsr dc_bit
        bcs @r
        ora dc_have,y
        sta dc_have,y
        jsr dc_to
        jsr reu_write
        jsr dc_back
@r:     clc
        rts

; dc_bit: rq_* -> Y = byte of dc_have, A = bit; carry set if no REU copy
dc_bit: lda dc_on
        beq @no
        lda rq_hi
        sta dc_hi
        lda rq_lo
        lsr dc_hi
        ror a
        lsr dc_hi
        ror a
        lsr dc_hi
        ror a
        tay
        lda rq_lo
        and #7
        tax
        lda #1
@s:     dex
        bmi @d
        asl a
        bne @s
@d:     clc
        rts
@no:    sec
        rts

; dc_to: rq_* = the copy's REU block (bank dc_base + block >> 8); dc_back
; puts the drive block back. Both clear carry.
dc_to:  lda rq_hi
        sta dc_hi
        clc
        adc dc_base
        sta rq_hi
        rts
dc_back:
        lda dc_hi
        sta rq_hi
        clc
        rts

; binval: A = dev. Forget its cached blocks (after the drive's own DOS
; changed the disk behind our back).
binval:
        ldx #NBUF-1
        sta tmp0
        cmp #0
        bne @l
        ldy #85             ; drive 8: its REU copy too
        lda #0
@c:     sta dc_have,y
        dey
        bpl @c
@l:     lda b_dev,x
        cmp tmp0
        bne @n
        lda #0
        sta b_valid,x
@n:     dex
        bpl @l
        rts

; cache_find: A = dev, X/Y = block. Hit: carry clear, X = idx, bp set.
cache_find:
        sta rq_dev
        stx rq_lo
        sty rq_hi
        inc b_clock
        bne @cl
        inc b_clock+1
@cl:    ldx #NBUF-1
@l:     lda b_valid,x
        beq @n
        lda b_dev,x
        cmp rq_dev
        bne @n
        lda b_lo,x
        cmp rq_lo
        bne @n
        lda b_hi,x
        cmp rq_hi
        bne @n
        jsr buf_touch
        jsr buf_idx_ptr
        clc
        rts
@n:     dex
        bpl @l
        sec
        rts

; cache_victim: choose a buffer (invalid, else least recently used),
; assign it to rq_*; sets b_idx and bp.
cache_victim:
        ldx #NBUF-1
@inv:   lda b_valid,x
        beq @got
        dex
        bpl @inv
        ; LRU: largest (clock - age), 16-bit
        lda #0
        sta lru_age
        sta lru_age+1
        ldx #NBUF-1
        stx b_idx
@l:     lda b_clock
        sec
        sbc b_age,x
        sta lru_cur
        lda b_clock+1
        sbc b_ageh,x
        cmp lru_age+1
        bcc @n
        bne @y
        ldy lru_cur
        cpy lru_age
        bcc @n
@y:     sta lru_age+1
        lda lru_cur
        sta lru_age
        stx b_idx
@n:     dex
        bpl @l
        ldx b_idx
@got:   stx b_idx
        lda b_dirty,x
        beq @clean
        jsr victim_flush
@clean: lda #0
        sta b_valid,x
        lda rq_dev
        sta b_dev,x
        lda rq_lo
        sta b_lo,x
        lda rq_hi
        sta b_hi,x
        jsr buf_touch
        jmp buf_idx_ptr

; victim_flush: X = b_idx = a changed buffer about to be reused: write it
; back first. Keeps the request (rq_*) and tmp0-tmp2, which callers of
; bread rely on. An I/O error here loses the block.
victim_flush:
        ldy #0
@s:     lda rq_dev,y
        pha
        lda tmp0,y
        pha
        iny
        cpy #3
        bne @s
        jsr bwrite
        ldy #2
@r:     pla
        sta tmp0,y
        pla
        sta rq_dev,y
        dey
        bpl @r
        ldx b_idx
        rts

; buf_touch: X = buffer, now the most recently used
buf_touch:
        lda b_clock
        sta b_age,x
        lda b_clock+1
        sta b_ageh,x
        rts

; ---- IEC (1541) ----
; rq_lo/hi -> trk/sec
blk_to_ts:
        ldx #34
@l:     lda rq_hi
        cmp trk_hi,x
        bcc @n
        bne @f
        lda rq_lo
        cmp trk_lo,x
        bcs @f
@n:     dex
        bpl @l
        ldx #0
@f:     lda rq_lo
        sec
        sbc trk_lo,x
        sta sct
        inx
        stx trk
        rts

; append decimal A (0-99) to cmdbuf
cmd_num:
        ldx #'0'-1
@t:     inx
        sec
        sbc #10
        bcs @t
        adc #10+'0'
        pha
        txa
        cmp #'0'
        beq @one
        jsr cmd_ch
@one:   pla
        ; fall through
cmd_ch: ldx cmdlen
        sta cmdbuf,x
        inc cmdlen
        rts

; build "U1:2 0 t s" style command; A = command letter digit ('1' or '2')
cmd_us:
        pha
        lda #0
        sta cmdlen
        lda #'U'
        jsr cmd_ch
        pla
        jsr cmd_ch
        lda #':'
        jsr cmd_ch
        lda #'2'
        jsr cmd_ch
        lda #' '
        jsr cmd_ch
        lda #'0'
        jsr cmd_ch
        lda #' '
        jsr cmd_ch
        lda trk
        jsr cmd_num
        lda #' '
        jsr cmd_ch
        lda sct
        jmp cmd_num

; send cmdbuf to the command channel
cmd_send:
        lda cur_drive
        ldy #$60+15
        jsr ieclisten
        bcs @r
        ldy #0
@l:     lda cmdbuf,y
        jsr iecout
        iny
        cpy cmdlen
        bne @l
        jmp iecunlisten
@r:     rts

; read the drive's error channel: carry set unless "00" or "01"
cmd_status:
        lda cur_drive
        ldy #$60+15
        jsr iectalk
        bcs @r
        jsr iecin
        sta tmp0
        jsr iecin
        sta tmp1
@skip:  lda ie_st
        bne @d              ; EOI or a bus error
        jsr iecin
        cmp #$0d
        bne @skip
@d:     jsr iecuntalk
        lda tmp0
        cmp #'0'
        bne @bad
        lda tmp1
        cmp #'2'            ; 00 or 01 are fine
        bcs @bad
        clc
        rts
@bad:   sec
@r:     rts

iec_read:
        jsr blk_to_ts
        jsr fast_read
        bcs @slow
        rts
@slow:  lda #'1'
        jsr cmd_us
        jsr cmd_send
        bcs @e
        jsr cmd_status
        bcs @e
        lda cur_drive
        ldy #$60+2
        jsr iectalk
        bcs @e
        ldy #0
@l:     jsr iecin
        bcs @x
        sta (bp),y
        iny
        bne @l
        jsr iecuntalk
        clc
        rts
@x:     jsr iecuntalk
@e:     sec
        rts

s_bp:   .byte "B-P:2 0"
iec_write:
        jsr blk_to_ts
        ldx #6
@c:     lda s_bp,x
        sta cmdbuf,x
        dex
        bpl @c
        lda #7
        sta cmdlen
        jsr cmd_send
        bcs @e
        lda cur_drive
        ldy #$60+2
        jsr ieclisten
        bcs @e
        ldy #0
@l:     lda (bp),y
        jsr iecout
        iny
        bne @l
        jsr iecunlisten
        bcs @e
        lda #'2'
        jsr cmd_us
        jsr cmd_send
        bcs @e
        jmp cmd_status
@e:     sec
        rts

; ---- fast read (the drive code in drive.s) ----
; fast_read: sector trk/sct of drive rq_dev into (bp). Carry set if it
; can't, or the read failed: the caller reads the slow way (and reports).
fast_read:
        ldx rq_dev
        lda dev_present,x
        beq @no             ; (raw diskio: unmounted drives read slowly)
        lda dev_type,x
        bne @no
        lda fl_bad,x
        bne @no
        lda fl_up,x
        bne @go
        jsr drv_upload
        bcs @bad
        ldx rq_dev
        inc fl_up,x
@go:    ldx #2              ; "M-E" lo hi track sector
@m:     lda s_me,x
        sta cmdbuf,x
        dex
        bpl @m
        lda #<DRV_ADDR
        sta cmdbuf+3
        lda #>DRV_ADDR
        sta cmdbuf+4
        lda trk
        sta cmdbuf+5
        lda sct
        sta cmdbuf+6
        lda #7
        sta cmdlen
        jsr cmd_send
        bcs @bad
        lda #0              ; the code runs (CLK low) within a second ...
        ldx #60
        ldy #0
        jsr cw
        bcs @bad
        lda #$40            ; ... and is done (CLK released) within 20
        ldx #<1200
        ldy #>1200
        jsr cw
        bcs @bad
        bit $dd00
        bpl @err            ; DATA low: the drive could not read it
        jmp fr_recv
@err:   lda $dd00           ; pull CLK and release it: status seen
        and #$07
        ora #$10
        sta $dd00
        ldx #20
@d:     dex
        bne @d
        and #$07
        sta $dd00
        sec
        rts
@bad:   ldx rq_dev          ; no drive code here (or it hangs): never again
        inc fl_bad,x
@no:    sec
        rts

; cw: A = $40 (until CLK is released) or 0 (until it is pulled), for at
; most X/Y jiffies; carry set on the timeout
cw:     sta cw_want
        stx cw_n
        sty cw_n+1
        lda ticks
        sta cw_t
@l:     lda $dd00
        and #$40
        cmp cw_want
        beq @ok
        lda ticks
        cmp cw_t
        beq @l
        sta cw_t
        lda cw_n
        bne @d
        lda cw_n+1
        beq @to
        dec cw_n+1
@d:     dec cw_n
        jmp @l
@ok:    clc
        rts
@to:    sec
        rts

; fr_recv: clock the 256 bytes in: pull CLK, wait for the drive to put a
; bit on DATA, read it; release CLK, the next bit. The drive answers each
; edge within ~21 us, so the C64 only ever waits longer than it must (a
; badline can't make it read early). A last pulse tells the drive the final
; bit has been read (it keeps DATA until then). Carry clear.
fr_recv:
        sei
        lda $dd00
        and #$07
        sta fr_off
        ora #$10
        sta fr_on
        ldy #0
@byte:  jsr fr_wait
        jsr fr_wait
        jsr ie_tick         ; the clock keeps time; and the drive fetches
        nop                 ; the next byte meanwhile (~66 us)
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ldx #4
@pair:  lda fr_on
        sta $dd00
        jsr fr_wait
        lda $dd00
        asl a
        rol fr_val
        lda fr_off
        sta $dd00
        jsr fr_wait
        lda $dd00
        asl a
        rol fr_val
        dex
        bne @pair
        lda fr_val
        sta (bp),y
        iny
        bne @byte
        lda fr_on           ; one more pulse: the drive holds the last bit
        sta $dd00           ; until it sees it
        jsr fr_wait
        lda fr_off
        sta $dd00
        cli
        clc
        rts
fr_wait:                    ; EXPERIMENT: 40 cycles
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        rts

; drv_upload: the drive code -> drive memory DRV_ADDR, 32 bytes per M-W
drv_upload:
        lda #0
        sta up_off
@c:     ldx #2              ; "M-W" lo hi n data
@m:     lda s_mw,x
        sta cmdbuf,x
        dex
        bpl @m
        lda #<DRV_ADDR
        clc
        adc up_off
        sta cmdbuf+3
        lda #>DRV_ADDR
        adc #0
        sta cmdbuf+4
        lda #<drv_size
        sec
        sbc up_off
        cmp #32
        bcc @n
        lda #32
@n:     sta up_n
        sta cmdbuf+5
        ldx up_off
        ldy #0
@d:     lda drv_code,x
        sta cmdbuf+6,y
        inx
        iny
        cpy up_n
        bne @d
        tya
        clc
        adc #6
        sta cmdlen
        jsr cmd_send
        bcs @r
        lda up_off
        clc
        adc up_n
        sta up_off
        cmp #<drv_size
        bcc @c
        clc
@r:     rts

s_me:   .byte "M-E"
s_mw:   .byte "M-W"

; ---- REU ----
reu_setup:                  ; rq_* and bp -> REU registers
        lda bp
        sta REU_C64LO
        lda bp+1
        sta REU_C64HI
        lda #0
        sta REU_LO
        sta REU_LENLO
        sta REU_CTRL
        lda rq_lo
        sta REU_HI
        lda rq_hi
        sta REU_BANK
        lda #1
        sta REU_LENHI
        rts

reu_read:
        lda ram_type
        cmp #2
        bne @reu
        jmp geo_read
@reu:   jsr reu_setup
        lda #$91
        sta REU_CMD
        clc
        rts

reu_write:
        lda ram_type
        cmp #2
        bne @reu
        jmp geo_write
@reu:   jsr reu_setup
        lda #$90
        sta REU_CMD
        clc
        rts

; transfer 1 byte (reu_tmp) to/from REU bank A offset 0; Y = command
reu_byte:
        sta REU_BANK
        lda #<reu_tmp
        sta REU_C64LO
        lda #>reu_tmp
        sta REU_C64HI
        lda #0
        sta REU_LO
        sta REU_HI
        sta REU_LENHI
        sta REU_CTRL
        lda #1
        sta REU_LENLO
        sty REU_CMD
        rts

reu_detect:
        lda #0
        sta reu_banks
        sta ram_type
        ldx #3
@p:     lda pat,x
        sta REU_C64LO,x
        dex
        bpl @p
        ldx #3
@q:     lda REU_C64LO,x
        cmp pat,x
        beq @qn
        jmp geo_detect
@qn:
        dex
        bpl @q
        ; keep what each bank holds (a preloaded disk image)
        ldx #127
@s:     txa
        ldy #$91
        jsr reu_byte
        lda reu_tmp
        sta reu_save,x
        dex
        bpl @s
        ; write bank number into each bank, highest first
        ldx #127
@w:     stx reu_tmp
        txa
        ldy #$90
        jsr reu_byte
        dex
        bpl @w
        ; count banks that read back their own number
        ldx #0
@r:     txa
        ldy #$91
        jsr reu_byte
        cpx reu_tmp
        bne @done
        inx
        cpx #128
        bne @r
@done:  stx reu_banks
        ldx #127            ; put the saved bytes back
@u:     lda reu_save,x
        sta reu_tmp
        txa
        ldy #$90
        jsr reu_byte
        dex
        bpl @u
        ldx reu_banks
        beq ram_none
        lda #1
ram_found:
        sta ram_type
        lda #1
        sta dev_present+1
        lda #FS_C64
        sta dev_type+1
ram_none:
        rts
pat:    .byte $5a, $a5, $3c, $c3

; ---- GeoRAM ----
geo_detect:
        lda #0
        sta GEO_BLK
        sta GEO_PAGE
        lda GEO_WIN
        sta reu_save        ; the probe below overwrites this byte
        lda #$5a            ; is there RAM in the window at all?
        sta GEO_WIN
        cmp GEO_WIN
        bne @none
        lda #$a5
        sta GEO_WIN
        cmp GEO_WIN
        bne @none
        lda reu_save
        sta GEO_WIN
        ; keep byte 0 of each 16 KB block (a preloaded disk image)
        ldx #0
@s:     stx GEO_BLK
        lda GEO_WIN
        sta reu_save,x
        inx
        bne @s
        ; write each 16 KB block's number into it, highest first: blocks
        ; past the end alias lower ones and get overwritten
        ldx #255
@w:     stx GEO_BLK
        stx GEO_WIN
        dex
        cpx #255
        bne @w
        ldx #0
@c:     stx GEO_BLK
        cpx GEO_WIN
        bne @n
        inx
        bne @c
        lda #64             ; 4 MB: all 256 blocks
        bne @b
@n:     txa
        lsr a
        lsr a
@b:     sta tmp0
        ldx #255            ; put the saved bytes back
@u:     stx GEO_BLK
        lda reu_save,x
        sta GEO_WIN
        dex
        cpx #255
        bne @u
        lda tmp0
        beq @none
        sta reu_banks
        lda #2
        jmp ram_found
@none:  rts

geo_sel:                    ; rq_hi:rq_lo -> GEO_BLK = block>>6, GEO_PAGE
        lda rq_lo
        and #$3f
        sta GEO_PAGE
        lda rq_hi
        sta reu_tmp
        lda rq_lo
        asl a
        rol reu_tmp
        asl a
        rol reu_tmp
        lda reu_tmp
        sta GEO_BLK
        ldy #0
        rts

geo_read:
        jsr geo_sel
@l:     lda GEO_WIN,y
        sta (bp),y
        iny
        bne @l
        clc
        rts

geo_write:
        jsr geo_sel
@l:     lda (bp),y
        sta GEO_WIN,y
        iny
        bne @l
        clc
        rts
