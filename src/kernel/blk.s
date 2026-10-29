; c64os block devices and buffer cache
;
; dev 0: 1541 on IEC device 8, raw 256-byte sectors via "U1"/"U2"/"B-P"
; dev 1: REU RAM disk (block b = REU bank b>>8, page b&$ff)
; Cache is write-through: bwrite writes the buffer to its device at once.
.include "k.inc"

LFN_CMD  = 15
LFN_DATA = 2
DRIVE    = 8

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

.segment "ZEROPAGE"
bp:      .res 2         ; pointer to the buffer returned by bread
.exportzp bp

.segment "BSS"
bufs:    .res NBUF*256
b_valid: .res NBUF
b_dev:   .res NBUF
b_lo:    .res NBUF
b_hi:    .res NBUF
b_age:   .res NBUF
b_clock: .res 1
b_idx:   .res 1
rq_dev:  .res 1
rq_lo:   .res 1
rq_hi:   .res 1
trk:     .res 1
sct:     .res 1
reu_banks: .res 1
dev_present: .res 2
cmdbuf:  .res 20
cmdlen:  .res 1
reu_tmp: .res 1

.export bwrite, buf_idx_ptr

.segment "RODATA"
; first linear block of each track (tracks 1..36), 16-bit
trk_lo: .lobytes 0,21,42,63,84,105,126,147,168,189,210,231,252,273,294,315,336,357,376,395,414,433,452,471,490,508,526,544,562,580,598,615,632,649,666,683
trk_hi: .hibytes 0,21,42,63,84,105,126,147,168,189,210,231,252,273,294,315,336,357,376,395,414,433,452,471,490,508,526,544,562,580,598,615,632,649,666,683
s_hash: .byte "#"
s_init: .byte "i0"

.segment "CODE"
blk_init:
        ldx #NBUF-1
        lda #0
@l:     sta b_valid,x
        dex
        bpl @l
        ; command channel
        lda #2
        ldx #<s_init
        ldy #>s_init
        jsr SETNAM
        lda #LFN_CMD
        ldx #DRIVE
        ldy #15
        jsr SETLFS
        jsr OPEN
        ; data channel with a drive buffer
        lda #1
        ldx #<s_hash
        ldy #>s_hash
        jsr SETNAM
        lda #LFN_DATA
        ldx #DRIVE
        ldy #2
        jsr SETLFS
        jsr OPEN
        jsr CLRCHN
        lda #1
        sta dev_present
        jmp reu_detect

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
        bne @reu
        jsr iec_read
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

; bwrite: X = buffer index. Write it to its device.
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
        bne @reu
        jsr iec_write
        jmp @r
@reu:   jsr reu_write
@r:     ldx b_idx
        bcc @ok
        lda #EIO
@ok:    rts
bdirty = bwrite

bflush_all:
binval:
        rts

; cache_find: A = dev, X/Y = block. Hit: carry clear, X = idx, bp set.
cache_find:
        sta rq_dev
        stx rq_lo
        sty rq_hi
        inc b_clock
        ldx #NBUF-1
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
        lda b_clock
        sta b_age,x
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
        ; LRU: largest (clock - age)
        lda #0
        sta tmp0
        ldx #NBUF-1
        stx b_idx
@l:     lda b_clock
        sec
        sbc b_age,x
        cmp tmp0
        bcc @n
        sta tmp0
        stx b_idx
@n:     dex
        bpl @l
        ldx b_idx
@got:   stx b_idx
        lda #0
        sta b_valid,x
        lda rq_dev
        sta b_dev,x
        lda rq_lo
        sta b_lo,x
        lda rq_hi
        sta b_hi,x
        lda b_clock
        sta b_age,x
        jmp buf_idx_ptr

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
        ldx #LFN_CMD
        jsr CHKOUT
        bcs @e
        ldy #0
@l:     lda cmdbuf,y
        jsr CHROUT
        iny
        cpy cmdlen
        bne @l
        jsr CLRCHN
        clc
        rts
@e:     jsr CLRCHN
        sec
        rts

; read the drive's error channel: carry set unless "00"
cmd_status:
        ldx #LFN_CMD
        jsr CHKIN
        jsr CHRIN
        sta tmp0
        jsr CHRIN
        sta tmp1
@skip:  jsr CHRIN
        cmp #$0d
        beq @d
        lda ST
        beq @skip
@d:     jsr CLRCHN
        lda tmp0
        cmp #'0'
        bne @bad
        lda tmp1
        cmp #'2'            ; 00 or 01 are fine
        bcs @bad
        clc
        rts
@bad:   sec
        rts

iec_read:
        jsr blk_to_ts
        lda #'1'
        jsr cmd_us
        jsr cmd_send
        bcs @e
        jsr cmd_status
        bcs @e
        ldx #LFN_DATA
        jsr CHKIN
        bcs @e
        ldy #0
@l:     jsr CHRIN
        sta (bp),y
        iny
        bne @l
        jsr CLRCHN
        clc
        rts
@e:     jsr CLRCHN
        sec
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
        ldx #LFN_DATA
        jsr CHKOUT
        bcs @e
        ldy #0
@l:     lda (bp),y
        jsr CHROUT
        iny
        bne @l
        jsr CLRCHN
        lda #'2'
        jsr cmd_us
        jsr cmd_send
        bcs @e
        jmp cmd_status
@e:     jsr CLRCHN
        sec
        rts

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
        jsr reu_setup
        lda #$91
        sta REU_CMD
        clc
        rts

reu_write:
        jsr reu_setup
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
        ldx #3
@p:     lda pat,x
        sta REU_C64LO,x
        dex
        bpl @p
        ldx #3
@q:     lda REU_C64LO,x
        cmp pat,x
        bne @none
        dex
        bpl @q
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
        cpx #0
        beq @none
        lda #1
        sta dev_present+1
@none:  rts
pat:    .byte $5a, $a5, $3c, $c3
