; format drive [cbm|c64fs] [name]: format the disk in drive 9, 10 or 11
;
;   cbm    a normal C64 disk (flat; other C64 software can read it)
;   c64fs  a Breadbin disk with directories (the default)
;
; Both start with the drive's own DOS format (N0:), which lays down the
; sector headers. For c64fs every sector is then marked used in the CBM
; BAM (so the drive's DOS leaves the disk alone) and a fresh c64fs is
; written: superblock at block 376, bitmap 377, inodes 378-393, root
; directory in block 1 (block numbers as in tools/mkimage.py).
.include "../../include/breadbin.inc"
.import argn, parse_dec, perr, print, eprint, newline
.importzp lp1, lp2

SB_BLOCK  = 376
BM_BLOCK  = 377
INO_START = 378
INO_BLKS  = 16
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
c64fs:  ; BAM: nothing free for the drive's DOS any more
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
        ; superblock
        jsr clear
        ldy #4
@mg:    lda magic,y
        sta blk,y
        dey
        bpl @mg
        lda #1
        sta blk+5
        lda #<683
        sta blk+6
        lda #>683
        sta blk+7
        lda #INO_BLKS*8
        sta blk+8
        lda #<BM_BLOCK
        sta blk+9
        lda #>BM_BLOCK
        sta blk+10
        lda #<INO_START
        sta blk+11
        lda #>INO_START
        sta blk+12
        lda #INO_BLKS
        sta blk+13
        lda #1
        sta blk+14
        lda #<SB_BLOCK
        ldx #>SB_BLOCK
        jsr wr
        ; bitmap: blocks 0-1, 357-393 and everything past 682 are used
        jsr clear
        lda #$03
        sta blk                 ; blocks 0 (never usable) and 1 (root dir)
        ldx #<357
        ldy #>357
@u1:    jsr setbit
        inx
        bne @n2
        iny
@n2:    cpy #>394
        bne @u1
        cpx #<394
        bne @u1
        ldx #<683
        ldy #>683
@u2:    jsr setbit
        inx
        bne @n3
        iny
@n3:    cpy #>2048
        bne @u2
        lda #<BM_BLOCK
        ldx #>BM_BLOCK
        jsr wr
        ; inode table: inode 0 reserved, inode 1 = root directory
        lda #0
        sta ib
@ib:    jsr clear
        lda ib
        bne @iw
        lda #$ff
        sta blk                 ; inode 0
        lda #2
        sta blk+32              ; inode 1: directory
        sta blk+33              ; nlink 2
        lda #32
        sta blk+34              ; size: two entries
        lda #ROOT_BLK
        sta blk+32+6            ; direct[0]
@iw:    lda ib
        clc
        adc #<INO_START
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
magic:     .byte "C64FS"
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
sy:    .res 1
t:     .res 1
mask:  .res 1
