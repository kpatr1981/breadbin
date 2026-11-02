; format drive [cbm|c64fs] [name]: format the disk in drive 9, 10 or 11
;
;   cbm    a normal C64 disk (flat; other C64 software can read it)
;   c64fs  a Breadbin disk with directories (the default)
;
; Both start with the drive's own DOS format (N0:), which lays down the
; sector headers. For c64fs every sector is then marked used in the CBM
; BAM (so the drive's DOS leaves the disk alone) and a fresh c64fs is
; written: superblock at block 376, bitmap 377, inodes 378-409, root
; directory in block 1. On a 1581 (3200 blocks) the bitmap takes 377-378,
; the inodes 379-410, and track 40 holds the CBM side (block numbers as in
; tools/mkimage.py).
.include "../../include/breadbin.inc"
.import argn, parse_dec, perr, print, eprint, newline
.importzp lp1, lp2

SB_BLOCK  = 376
BM_BLOCK  = 377
INO_START = 378
INO_BLKS  = 32           ; 4 inodes of 64 bytes per block: 128 inodes
INO_SIZE  = 64
ROOT_BLK  = 1
BAM_BLOCK = 357

.segment "CODE"
start:  lda argc
        cmp #2
        bcs @a
        jmp usage
@a:     lda #1
        jsr argn
        jsr parse_dec
        bcc @d
        jmp usage
@d:     sta drive
        cmp #9              ; drive 8 holds the running system
        bcc @bad
        cmp #12
        bcc @ok
@bad:   lda #<s_drives
        ldx #>s_drives
        jsr eprint
        lda #1
        jmp SYS_EXIT
@ok:    lda #1
        sta kind            ; 1 = c64fs
        lda #<def_name
        sta name
        lda #>def_name
        sta name+1
        lda #2
        jsr argn
        bcs @go
        sta lp1
        stx lp1+1
        lda #<s_cbm
        sta lp2
        lda #>s_cbm
        sta lp2+1
        jsr streq
        bne @n1
        lda #0
        sta kind
        jmp @nm
@n1:    lda #<s_c64fs
        sta lp2
        lda #>s_c64fs
        sta lp2+1
        jsr streq
        beq @nm
        jmp usage
@nm:    lda #3
        jsr argn
        bcs @go
        sta name
        stx name+1
@go:    ; are you sure?
        lda #<s_ask1
        ldx #>s_ask1
        jsr print
        jsr pdrive
        lda #<s_ask2
        ldx #>s_ask2
        jsr print
        lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        lda #8
        sta r1
        lda #0
        sta r1+1
        lda #0
        jsr SYS_READ
        lda buf
        cmp #'y'
        beq @yes
        lda #<s_cancel
        ldx #>s_cancel
        jsr print
        lda #1
        jmp SYS_EXIT
@yes:   lda #<s_working
        ldx #>s_working
        jsr print
        ; "N0:name,BB" (name in PETSCII: lowercase ASCII -> unshifted)
        ldx #0
        lda #'N'
        sta buf,x
        inx
        lda #'0'
        sta buf,x
        inx
        lda #':'
        sta buf,x
        inx
        lda name
        sta lp1
        lda name+1
        sta lp1+1
        ldy #0
@cn:    lda (lp1),y
        beq @ce
        cmp #'a'
        bcc @cs
        cmp #'z'+1
        bcs @cs
        and #$df            ; a-z -> PETSCII $41-$5a
@cs:    sta buf,x
        inx
        iny
        cpy #16
        bcc @cn
@ce:    lda #','
        sta buf,x
        inx
        lda #'B'
        sta buf,x
        inx
        sta buf,x
        inx
        lda #0
        sta buf,x
        lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        lda drive
        ldx #0
        jsr SYS_DISKIO
        bcc @fmt
        jmp fail
@fmt:   lda kind
        bne c64fs
        jmp done

; ---- c64fs on top of the fresh DOS format ----
c64fs:  ; a 1581? Its header, 40/0 (block 1560 in its numbering), has format
        ; 'D'; on a 1541 that block doesn't exist
        lda #0
        sta geo
        lda #<1560
        ldx #>1560
        jsr rd_try
        bcs @g
        lda blk+2
        cmp #'D'
        bne @g
        inc geo
@g:     ; BAM: nothing free for the drive's DOS any more
        lda geo
        bne @bam81
        lda #<BAM_BLOCK
        ldx #>BAM_BLOCK
        jsr rd
        ldy #4
        lda #0
@bam:   sta blk,y
        iny
        cpy #144
        bne @bam
        lda #<BAM_BLOCK
        ldx #>BAM_BLOCK
        jsr wr
        jmp @sb
@bam81: lda #<1561          ; 40/1 and 40/2: 6 bytes per track from $10
        jsr bam81
        lda #<1562
        jsr bam81
@sb:    ; superblock
        jsr clear
        ldy #C64FS_MAGIC_LEN-1
@mg:    lda magic,y
        sta blk,y
        dey
        bpl @mg
        lda #C64FS_VERSION
        sta blk+5
        ldx geo
        lda nb_lo,x
        sta blk+6
        lda nb_hi,x
        sta blk+7
        lda #INO_BLKS*4
        sta blk+8
        lda #<BM_BLOCK
        sta blk+9
        lda #>BM_BLOCK
        sta blk+10
        lda is_lo,x
        sta blk+11
        sta istart
        lda #>INO_START
        sta blk+12
        lda #INO_BLKS
        sta blk+13
        lda #1
        sta blk+14
        lda #<SB_BLOCK
        ldx #>SB_BLOCK
        jsr wr
        ; bitmap (blocks 0-2047): 0 (never usable), 1 (root directory), the
        ; superblock, bitmap and inode blocks, the CBM directory track, and
        ; on a 1541 everything past 682
        jsr clear
        lda #$03
        sta blk
        lda istart
        clc
        adc #INO_BLKS
        sta re_lo
        lda #>INO_START
        sta re_hi
        ldx #<SB_BLOCK
        ldy #>SB_BLOCK
        jsr mark
        lda geo
        bne @t40
        lda #<376
        sta re_lo
        lda #>376
        sta re_hi
        ldx #<357
        ldy #>357
        jsr mark
        lda #<2048
        sta re_lo
        lda #>2048
        sta re_hi
        ldx #<683
        ldy #>683
        jsr mark
        jmp @bmw
@t40:   lda #<1600
        sta re_lo
        lda #>1600
        sta re_hi
        ldx #<1560
        ldy #>1560
        jsr mark
@bmw:   lda #<BM_BLOCK
        ldx #>BM_BLOCK
        jsr wr
        lda geo             ; a 1581: the second bitmap block, blocks
        beq @ino            ; 2048-4095, of which 3200 on are past the end
        jsr clear
        ldy #144
        lda #$ff
@pe:    sta blk,y
        iny
        bne @pe
        lda #<(BM_BLOCK+1)
        ldx #>(BM_BLOCK+1)
        jsr wr
@ino:   ; inode table: inode 0 reserved, inode 1 = root directory
        lda #0
        sta ib
@ib:    jsr clear
        lda ib
        bne @iw
        lda #$ff
        sta blk                 ; inode 0
        lda #2
        sta blk+INO_SIZE        ; inode 1: directory
        sta blk+INO_SIZE+1      ; nlink 2
        lda #32
        sta blk+INO_SIZE+2      ; size: two entries
        lda #ROOT_BLK
        sta blk+INO_SIZE+6      ; direct[0]
@iw:    lda ib
        clc
        adc istart
        pha
        lda #>INO_START
        adc #0
        tax
        pla
        jsr wr
        inc ib
        lda ib
        cmp #INO_BLKS
        bne @ib
        ; root directory: . and ..
        jsr clear
        lda #1
        sta blk
        sta blk+16
        lda #'.'
        sta blk+1
        sta blk+17
        sta blk+18
        lda #ROOT_BLK
        ldx #0
        jsr wr
done:   lda #<s_done
        ldx #>s_done
        jsr print
        lda #0
        jmp SYS_EXIT

fail:   ldx #0
        ldy #0
        jsr perr
        lda #1
        jmp SYS_EXIT

usage:  lda #<s_usage
        ldx #>s_usage
        jsr eprint
        lda #1
        jmp SYS_EXIT

; rd / wr: block A/X <-> blk
rd:     sta r1
        stx r1+1
        lda #<blk
        sta r0
        lda #>blk
        sta r0+1
        lda drive
        ldx #2
        jsr SYS_DISKIO
        bcs fail
        rts
wr:     sta r1
        stx r1+1
        lda #<blk
        sta r0
        lda #>blk
        sta r0+1
        lda drive
        ldx #1
        jsr SYS_DISKIO
        bcs fail
        rts

clear:  lda #0
        tay
@l:     sta blk,y
        iny
        bne @l
        rts

; setbit: mark block X/Y used in the bitmap in blk (preserves X/Y)
setbit: stx sx
        sty sy
        txa
        and #7
        tax
        lda #1
@s:     dex
        bmi @m
        asl a
        jmp @s
@m:     sta mask
        lda sy
        sta t
        lda sx
        lsr t
        ror a
        lsr t
        ror a
        lsr t
        ror a
        tay
        lda blk,y
        ora mask
        sta blk,y
        ldx sx
        ldy sy
        rts

; mark: set blocks X/Y .. re_hi/re_lo - 1 in the bitmap in blk
mark:   jsr setbit
        inx
        bne @c
        iny
@c:     cpy re_hi
        bne mark
        cpx re_lo
        bne mark
        rts

; bam81: A = low byte of a 1581 BAM block (high: 6): no track free there
bam81:  sta bb
        ldx #>1561
        jsr rd
        ldy #$10
        lda #0
@z:     sta blk,y
        iny
        bne @z
        lda bb
        ldx #>1561
        jmp wr

; rd_try: block A/X -> blk; carry set if it can't be read
rd_try: sta r1
        stx r1+1
        lda #<blk
        sta r0
        lda #>blk
        sta r0+1
        lda drive
        ldx #2
        jmp SYS_DISKIO

; streq: (lp1) == (lp2) -> Z set
streq:  ldy #0
@l:     lda (lp1),y
        cmp (lp2),y
        bne @r
        cmp #0
        beq @r
        iny
        bne @l
@r:     rts

; pdrive: print the drive number
pdrive: lda drive
        ldx #0
        .import print_dec
        jmp print_dec

.segment "RODATA"
magic:     .byte C64FS_MAGIC
nb_lo:     .byte <683, <3200   ; blocks: 1541, 1581
nb_hi:     .byte >683, >3200
is_lo:     .byte <378, <379    ; first inode block (high byte 1)
def_name:  .byte "breadbin", 0
s_cbm:     .byte "cbm", 0
s_c64fs:   .byte "c64fs", 0
s_usage:   .byte "usage: format drive [cbm|c64fs] [name]", 10, 0
s_ask1:    .byte "erase everything on drive ", 0
s_ask2:    .byte "? (y/n) ", 0
s_cancel:  .byte "cancelled", 10, 0
s_drives:  .byte "format: only drives 9, 10 and 11 can be formatted", 10, 0
s_working: .byte "formatting, this takes a while...", 10, 0
s_done:    .byte "done", 10, 0

.segment "BSS"
drive: .res 1
kind:  .res 1
name:  .res 2
ib:    .res 1
buf:   .res 48
blk:   .res 256
sx:    .res 1
geo:   .res 1      ; 0: a 1541, 1: a 1581
istart: .res 1
re_lo: .res 1
re_hi: .res 1
bb:    .res 1
sy:    .res 1
t:     .res 1
mask:  .res 1
