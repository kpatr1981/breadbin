; fsck [-f] [dir]: check the c64fs that holds dir (default /); -f repairs it
;
; Checks directory entries (they must point to inodes in use), link counts,
; inodes that no directory reaches, blocks used twice, and the block bitmap
; against the blocks the inodes actually use. On a 1541 disk the CBM side
; (track 18 and the files in its directory, i.e. the boot file) counts as
; used. Run it while nothing else writes to that disk: an open file that was
; unlinked looks like an orphan.
.include "../../include/breadbin.inc"
.import argn, perr, eprint, print, print_dec, newline, putc
.importzp lp1, lp2

ptr  = $23              ; general pointers
ptr2 = $25
n    = $27              ; inode number
d    = $28              ; directory inode being read
fix  = $29              ; -f
dev  = $2a
nent = $2b              ; entries left in a directory block
blk  = $2c              ; a block number (2)
sb_at = $2e             ; superblock block, low byte (high: sb_ath): 376 or 0

SB_DISK = 376

.segment "CODE"
start:  lda #0
        sta fix
        sta probs
        sta probs+1
        lda #<s_root
        sta path
        lda #>s_root
        sta path+1
        lda #1
        jsr argn
        bcs @go
        sta lp1
        stx lp1+1
        ldy #0
        lda (lp1),y
        cmp #'-'
        bne @p0
        iny
        lda (lp1),y
        cmp #'f'
        bne @usage
        inc fix
        lda #2
        jsr argn
        bcs @go
        bcc @p1
@p0:    lda lp1
        ldx lp1+1
@p1:    sta path
        stx path+1
@go:    jsr load
        bcc @ok
        rts
@ok:    jsr walk
        jsr check_inodes
        lda #0              ; the bitmap, 2048 blocks (one bitmap block) at a time
        sta chunk
@chunk: jsr mark_used
        jsr check_bitmap
        bcs @sum
        inc chunk
        lda chunk
        cmp nbm
        bcc @chunk
        lda fix
        beq @sum
        jsr write_back
@sum:   lda probs
        ora probs+1
        bne @n
        lda #<s_clean
        ldx #>s_clean
        jmp print
@n:     lda probs
        ldx probs+1
        jsr print_dec
        lda #<s_probs
        ldx #>s_probs
        jsr print
        lda fix
        beq @nl
        lda #<s_fixed
        ldx #>s_fixed
        jsr print
@nl:    jmp newline
@usage: lda #<s_usage
        ldx #>s_usage
        jsr eprint
        lda #2
        jmp SYS_EXIT

; ---- loading ----
; load: stat the path, find the superblock, read the bitmap and inodes
load:   lda path
        sta r0
        lda path+1
        sta r0+1
        lda #<stbuf
        sta r1
        lda #>stbuf
        sta r1+1
        jsr SYS_STAT
        bcs @err
        lda stbuf+6
        sta dev
        lda #<SB_DISK
        sta sb_at
        lda #>SB_DISK
        sta sb_ath
        jsr read_sb
        bcc @sb
        lda #0
        sta sb_at
        sta sb_ath
        jsr read_sb
        bcc @sb
        lda #<s_nofs
        ldx #>s_nofs
        jsr eprint
        sec
        rts
@err:   ldx path
        ldy path+1
        jsr perr
        sec
        rts
@sb:    lda sb+6
        sta nblocks
        lda sb+7
        sta nblocks+1
        lda sb+8
        sta ninodes
        lda sb+9
        sta bmblk
        lda sb+10
        sta bmblk+1
        lda sb+11
        sta istart
        lda sb+12
        sta istart+1
        lda sb+14
        sta root
        lda istart          ; bitmap blocks: up to the inode table
        sec
        sbc bmblk
        sta nbm
        lda sb+13           ; inode blocks
        sta niblk
        lda nblocks+1       ; 3200 blocks: a 1581
        cmp #>3200
        lda #0
        rol a
        sta d81
        ; inodes: the first 32 bytes of each (the times aren't checked)
        lda #0
        sta n
@ib:    lda n
        cmp niblk
        bcs @done
        jsr rd_iblk
        bcs @ioerr
        ldy #0
@g:     lda ibuf,x
        sta (ptr2),y
        jsr ib_next
        bne @g
        inc n
        bne @ib
@done:  clc
        rts
@ioerr: ldx #0
        ldy #0
        jsr perr
        sec
        rts

; read_sb: block sb_at -> sb; carry clear if it holds the c64fs magic
read_sb:
        lda sb_at
        sta blk
        lda sb_ath
        sta blk+1
        lda #<sb
        ldx #>sb
        jsr rdblk
        bcs @r
        ldx #C64FS_MAGIC_LEN-1
@m:     lda sb,x
        cmp magic,x
        bne @no
        dex
        bpl @m
        clc
@r:     rts
@no:    sec
        rts

; rdblk / wrblk: block blk <-> the 256 bytes at A/X
rdblk:  ldy #3
        .byte $2c
wrblk:  ldy #4
        sta r0
        stx r0+1
        lda blk
        sta r1
        lda blk+1
        sta r1+1
        tya
        tax
        lda dev
        jmp SYS_DISKIO

; ---- directories ----
; walk: from the root, count the directory entries that point at each
; inode (links) and queue every directory reached; entries pointing to free
; inodes are problems (removed with -f)
walk:   lda root
        sta queue
        ldx root
        lda #1
        sta seen,x
        lda #1
        sta qlen
        lda #0
        sta qpos
@next:  lda qpos
        cmp qlen
        bcc @d
        rts
@d:     tax
        lda queue,x
        sta d
        inc qpos
        lda #0
        sta bi
@blk:   jsr dir_block       ; block bi of d -> dbuf, carry set when past the end
        bcs @next
        lda #<dbuf
        sta ptr
        lda #>dbuf
        sta ptr+1
        lda #16
        sta nent
        lda #0
        sta dchg
@ent:   ldy #0
        lda (ptr),y
        beq @en
        tax
        cpx ninodes
        bcs @bad
        jsr inoptr          ; X = inode -> ptr2
        ldy #0
        lda (ptr2),y
        beq @bad
        ldx n
        inc links,x
        cmp #T_DIR
        bne @en
        jsr is_dot
        beq @en
        ldx n
        lda seen,x
        bne @en
        inc seen,x
        txa
        ldx qlen
        sta queue,x
        inc qlen
        jmp @en
@bad:   stx n
        lda #<s_entry
        ldx #>s_entry
        jsr print
        jsr print_name
        lda #<s_free
        ldx #>s_free
        jsr print
        lda n
        ldx #0
        jsr print_dec
        jsr problem
        lda fix
        beq @en
        lda #0
        tay
        sta (ptr),y
        inc dchg
@en:    lda ptr
        clc
        adc #16
        sta ptr
        bcc @e2
        inc ptr+1
@e2:    dec nent
        bne @ent
        lda dchg
        beq @nw
        lda #<dbuf
        ldx #>dbuf
        jsr wrblk
@nw:    inc bi
        jmp @blk

; dir_block: block bi of directory d -> dbuf (blk set); carry set past the end
dir_block:
        ldx d
        jsr inoptr
        ; past the end? bi * 256 >= size
        ldy #4
        lda (ptr2),y        ; size bits 16-23
        bne @in
        dey
        lda (ptr2),y        ; size bits 8-15
        cmp bi
        beq @part
        bcs @in
        sec
        rts
@part:  dey
        lda (ptr2),y        ; a partial last block?
        bne @in
        sec
        rts
@in:    lda bi
        jsr bmap
        bcs @r
        lda blk
        ora blk+1
        beq @hole
        lda #<dbuf
        ldx #>dbuf
        jmp rdblk
@hole:  sec
@r:     rts

; bmap: A = file block index of inode at ptr2 -> blk (0 = hole)
bmap:   cmp #12
        bcs @ind
        asl a
        adc #6
        tay
        lda (ptr2),y
        sta blk
        iny
        lda (ptr2),y
        sta blk+1
        clc
        rts
@ind:   sec
        sbc #12
        sta tmp
        ldy #30
        lda (ptr2),y
        sta blk
        iny
        lda (ptr2),y
        sta blk+1
        ora blk
        beq @r
        lda #<ibuf
        ldx #>ibuf
        jsr rdblk
        bcs @r
        lda tmp
        asl a
        tay
        lda ibuf,y
        sta blk
        lda ibuf+1,y
        sta blk+1
@r:     clc
        rts

; is_dot: Z set if the entry at ptr is "." or ".."
is_dot: ldy #1
        lda (ptr),y
        cmp #'.'
        bne @r
        iny
        lda (ptr),y
        beq @r
        cmp #'.'
        bne @r
        iny
        lda (ptr),y
@r:     rts

print_name:
        ldy #1
@l:     lda (ptr),y
        beq @r
        sty tmp
        jsr putc
        ldy tmp
        iny
        cpy #16
        bne @l
@r:     rts

; ---- inodes ----
; check_inodes: inodes in use that no directory reaches are orphans (freed
; with -f); the others must have as many links as entries point at them
check_inodes:
        lda #1
        sta n
@l:     lda n
        cmp ninodes
        bcc @c
        rts
@c:     tax
        jsr inoptr
        ldy #0
        lda (ptr2),y
        beq @nx
        ldx n
        lda links,x
        bne @lk
        lda #<s_inode
        ldx #>s_inode
        jsr print_ino
        lda #<s_orphan
        ldx #>s_orphan
        jsr print
        jsr problem
        lda fix
        beq @nx
        lda #0              ; free it: its blocks become free below
        tay
        sta (ptr2),y
        jsr ino_dirty
        jmp @nx
@lk:    ldy #1
        cmp (ptr2),y
        beq @nx
        lda #<s_inode
        ldx #>s_inode
        jsr print_ino
        lda #<s_links
        ldx #>s_links
        jsr print
        ldy #1
        lda (ptr2),y
        ldx #0
        jsr print_dec
        lda #<s_should
        ldx #>s_should
        jsr print
        ldx n
        lda links,x
        ldx #0
        jsr print_dec
        jsr problem
        lda fix
        beq @nx
        ldx n
        lda links,x
        ldy #1
        sta (ptr2),y
        jsr ino_dirty
@nx:    inc n
        jmp @l

; print_ino: print A/X, then " n"
print_ino:
        jsr print
        lda n
        ldx #0
        jmp print_dec

; ino_dirty: the inode block of inode n changed
ino_dirty:
        lda n
        lsr a
        lsr a
        tax
        lda #1
        sta ibdirty,x
        rts

; inoptr: X = inode -> ptr2 = &inodes[X * 32], n = X
inoptr: stx n
        txa
        lsr a
        lsr a
        lsr a
        sta ptr2+1
        txa
        asl a
        asl a
        asl a
        asl a
        asl a
        clc
        adc #<inodes
        sta ptr2
        lda ptr2+1
        adc #>inodes
        sta ptr2+1
        rts

; ---- blocks ----
; mark_used: the blocks (of this chunk) that must be marked used: the
; superblock, bitmap and inode blocks, the CBM side of a 1541 disk, and
; every inode's blocks
mark_used:
        ldy #0
        tya
@z:     sta used,y
        iny
        bne @z
        lda sb_at
        sta blk
        lda sb_ath
        sta blk+1
        jsr use
        lda #0
        sta n
@bb:    lda bmblk           ; the bitmap blocks
        clc
        adc n
        sta blk
        lda bmblk+1
        adc #0
        sta blk+1
        jsr use
        inc n
        lda n
        cmp nbm
        bcc @bb
        lda #0
        sta n
@ib:    lda n
        cmp niblk
        bcs @cbm
        clc
        adc istart
        sta blk
        lda istart+1
        adc #0
        sta blk+1
        jsr use
        inc n
        bne @ib
@cbm:   lda sb_at
        ora sb_ath
        beq @inodes
        jsr mark_cbm
@inodes:
        lda #0              ; block 0: never usable (0 in an inode = none);
        sta blk             ; marked after mark_cbm, which takes a block
        sta blk+1           ; marked already for a loop in a chain
        jsr use
        lda #1
        sta n
@l:     lda n
        cmp ninodes
        bcc @c
        rts
@c:     tax
        jsr inoptr
        ldy #0
        lda (ptr2),y
        beq @nx
        cmp #T_CHR
        beq @nx
        ldy #6              ; 12 direct blocks
@d:     sty tmp2
        lda (ptr2),y
        sta blk
        iny
        lda (ptr2),y
        sta blk+1
        jsr use_ino
        ldy tmp2
        iny
        iny
        cpy #30
        bne @d
        lda (ptr2),y        ; the indirect block and its entries
        sta blk
        iny
        lda (ptr2),y
        sta blk+1
        ora blk
        beq @nx
        jsr use_ino
        lda #<ibuf
        ldx #>ibuf
        jsr rdblk
        bcs @nx
        ldy #0
@i:     sty tmp2
        lda ibuf,y
        sta blk
        lda ibuf+1,y
        sta blk+1
        jsr use_ino
        ldy tmp2
        iny
        iny
        bne @i
@nx:    inc n
        jmp @l

; mark_cbm: the CBM directory track (18 on a 1541, 40 on a 1581) and the
; blocks of every file in the CBM directory
mark_cbm:
        ldx d81
        lda dts_lo,x
        sta blk
        lda dts_hi,x
        sta blk+1
@trk:   jsr use
        inc blk
        bne @tc
        inc blk+1
@tc:    ldx d81
        lda blk
        cmp dte_lo,x
        bne @trk
        lda blk+1
        cmp dte_hi,x
        bne @trk
        lda dir_t,x         ; directory chain from 18/1 or 40/3
        sta dt
        lda dir_s,x
        sta ds
@dir:   lda dt
        beq @r
        ldx ds
        jsr ts_blk
        lda #<dbuf
        ldx #>dbuf
        jsr rdblk
        bcs @r
        lda dbuf
        sta dt
        lda dbuf+1
        sta ds
        ldx #0              ; 8 entries of 32 bytes
@e:     stx tmp2
        lda dbuf+2,x        ; file type: 0 = empty slot
        beq @en
        lda dbuf+3,x
        sta ft
        lda dbuf+4,x
        sta fs
@f:     lda ft              ; follow the file's sector chain
        beq @en
        ldx d81
        cmp max_t,x
        bcs @en
        ldx fs
        jsr ts_blk
        jsr bitpos
        bcs @en
        and used,y
        bne @en             ; seen already: the chain loops
        jsr use
        lda #<ibuf
        ldx #>ibuf
        jsr rdblk
        bcs @en
        lda ibuf
        sta ft
        lda ibuf+1
        sta fs
        jmp @f
@en:    lda tmp2
        clc
        adc #32
        tax
        bne @e
        jmp @dir
@r:     rts

; ts_blk: A = track, X = sector -> blk
ts_blk: ldy d81
        bne @81
        tay
        dey
        txa
        clc
        adc trk_lo,y
        sta blk
        lda trk_hi,y
        adc #0
        sta blk+1
        rts
@81:    stx tmp3            ; a 1581: (track - 1) * 40 + sector
        sec
        sbc #1
        sta blk
        lda #0
        sta blk+1
        ldy #3
@x8:    asl blk
        rol blk+1
        dey
        bne @x8
        lda blk             ; * 8, then * 32, added
        sta t8
        lda blk+1
        sta t8+1
        asl blk
        rol blk+1
        asl blk
        rol blk+1
        lda blk
        clc
        adc t8
        sta blk
        lda blk+1
        adc t8+1
        sta blk+1
        lda blk
        clc
        adc tmp3
        sta blk
        bcc @r
        inc blk+1
@r:     rts

; bitpos: blk -> Y = byte in the chunk's bitmap, A = its bit; carry set if
; blk is not in this chunk (blocks chunk * 2048 .. +2047)
bitpos: lda blk+1
        lsr a
        lsr a
        lsr a
        cmp chunk
        bne @no
        lda blk+1
        and #7
        sta tmp3
        lda blk
        lsr tmp3
        ror a
        lsr tmp3
        ror a
        lsr tmp3
        ror a
        tay
        lda blk
        and #7
        tax
        lda bits,x
        clc
        rts
@no:    sec
        rts

; use: mark blk used (reserved blocks)
use:    jsr bitpos
        bcs @r
        ora used,y
        sta used,y
@r:     rts

; use_ino: blk (0 = none) belongs to inode n: it must be on the disk and
; not belong to anything else
use_ino:
        lda blk
        ora blk+1
        beq @r
        lda blk+1
        cmp nblocks+1
        bcc @in
        bne @bad
        lda blk
        cmp nblocks
        bcs @bad
@in:    jsr bitpos
        bcs @r              ; another chunk's
        sta tmp
        and used,y
        bne @twice
        lda tmp
        ora used,y
        sta used,y
@r:     rts
@bad:   lda chunk           ; reported once, in the first chunk
        bne @r
        lda #<s_inode
        ldx #>s_inode
        jsr print_ino
        lda #<s_range
        ldx #>s_range
        jsr print
        jmp problem
@twice: jsr print_blk
        lda #<s_twice
        ldx #>s_twice
        jsr print
        jmp problem

print_blk:
        lda #<s_blk
        ldx #>s_blk
        jsr print
        lda blk
        ldx blk+1
        jmp print_dec

; check_bitmap: the chunk's blocks below nblocks: used <-> marked in its
; bitmap block (written back with -f). Carry set on a read error.
check_bitmap:
        lda bmblk
        clc
        adc chunk
        sta blk
        lda bmblk+1
        adc #0
        sta blk+1
        lda #<bm
        ldx #>bm
        jsr rdblk
        bcc @rd
        rts
@rd:    lda #0
        sta blk
        sta bmchg
        lda chunk
        asl a
        asl a
        asl a
        sta blk+1
@l:     lda blk+1
        lsr a
        lsr a
        lsr a
        cmp chunk
        bne @r              ; past this chunk
        lda blk+1
        cmp nblocks+1
        bcc @c
        bne @r
        lda blk
        cmp nblocks
        bcs @r
@c:     jsr bitpos
        sta tmp
        and used,y
        sta tmp2
        lda tmp
        and bm,y
        cmp tmp2
        beq @nx
        jsr print_blk
        lda tmp2
        beq @leak
        lda #<s_infree
        ldx #>s_infree
        jsr print
        jsr problem
        lda fix
        beq @nx
        jsr bitpos
        ora bm,y
        sta bm,y
        inc bmchg
        jmp @nx
@leak:  lda #<s_leak
        ldx #>s_leak
        jsr print
        jsr problem
        lda fix
        beq @nx
        jsr bitpos
        eor #$ff
        and bm,y
        sta bm,y
        inc bmchg
@nx:    inc blk
        bne @l
        inc blk+1
        jmp @l
@r:     lda bmchg
        beq @ok
        lda bmblk
        clc
        adc chunk
        sta blk
        lda bmblk+1
        adc #0
        sta blk+1
        lda #<bm
        ldx #>bm
        jsr wrblk
@ok:    clc
        rts

; write_back: changed inode blocks, then sync
write_back:
        lda #0
        sta n
@ib:    lda n
        cmp niblk
        bcs @bm
        tax
        lda ibdirty,x
        beq @nx
        jsr rd_iblk         ; the block as it is, so the times stay
        bcs @nx
        ldy #0
@p:     lda (ptr2),y
        sta ibuf,x
        jsr ib_next
        bne @p
        lda #<ibuf
        ldx #>ibuf
        jsr wrblk
@nx:    inc n
        bne @ib
@bm:    jmp SYS_SYNC

; rd_iblk: inode block n -> ibuf; ptr2 = its 4 inodes in inodes (32 bytes
; each), X = Y = 0 for ib_next
rd_iblk:
        lda n
        clc
        adc istart
        sta blk
        lda istart+1
        adc #0
        sta blk+1
        lda n               ; ptr2 = inodes + n * 128
        lsr a
        tax
        lda #0
        ror a
        clc
        adc #<inodes
        sta ptr2
        txa
        adc #>inodes
        sta ptr2+1
        lda #<ibuf
        ldx #>ibuf
        jsr rdblk
        ldx #0
        rts

; ib_next: step X (ibuf, 64 per inode) and Y (inodes, 32 per inode)
; over the first 32 bytes of each inode; Z set after the fourth
ib_next:
        inx
        iny
        tya
        and #31
        bne @r
        txa
        clc
        adc #32
        tax
        cpy #128
@r:     rts

; problem: one more problem; ends its line
problem:
        inc probs
        bne @n
        inc probs+1
@n:     jmp newline

.segment "RODATA"
magic:   .byte C64FS_MAGIC
dts_lo:  .byte <357, <1560      ; CBM directory track: 1541, 1581
dts_hi:  .byte >357, >1560
dte_lo:  .byte <376, <1600
dte_hi:  .byte >376, >1600
dir_t:   .byte 18, 40           ; first directory block
dir_s:   .byte 1, 3
max_t:   .byte 36, 81
bits:    .byte 1, 2, 4, 8, 16, 32, 64, 128
trk_lo:  .lobytes 0,21,42,63,84,105,126,147,168,189,210,231,252,273,294,315,336,357,376,395,414,433,452,471,490,508,526,544,562,580,598,615,632,649,666
trk_hi:  .hibytes 0,21,42,63,84,105,126,147,168,189,210,231,252,273,294,315,336,357,376,395,414,433,452,471,490,508,526,544,562,580,598,615,632,649,666
s_root:  .byte "/", 0
s_usage: .byte "usage: fsck [-f] [dir]", 10, 0
s_nofs:  .byte "fsck: not a c64fs disk", 10, 0
s_clean: .byte "clean", 10, 0
s_probs: .byte " problems", 0
s_fixed: .byte ", fixed", 0
s_entry: .byte "entry ", 0
s_free:  .byte " -> free inode ", 0
s_inode: .byte "inode ", 0
s_orphan: .byte ": in no directory", 0
s_links: .byte ": links ", 0
s_should: .byte ", should be ", 0
s_range: .byte ": block out of range", 0
s_blk:   .byte "block ", 0
s_twice: .byte ": used twice", 0
s_infree: .byte ": in use, marked free", 0
s_leak:  .byte ": marked used, not in use", 0

.segment "BSS"
path:    .res 2
probs:   .res 2
stbuf:   .res 16
nblocks: .res 2
ninodes: .res 1
niblk:   .res 1
nbm:     .res 1
chunk:   .res 1
bmblk:   .res 2
istart:  .res 2
root:    .res 1
sb_ath:  .res 1
qlen:    .res 1
qpos:    .res 1
bi:      .res 1
dchg:    .res 1
bmchg:   .res 1
tmp:     .res 1
tmp2:    .res 1
tmp3:    .res 1
dt:      .res 1
ds:      .res 1
ft:      .res 1
fs:      .res 1
ibdirty: .res 64
d81:     .res 1
t8:      .res 2
sb:      .res 256
bm:      .res 256
used:    .res 256
links:   .res 256
seen:    .res 256
queue:   .res 256
dbuf:    .res 256
ibuf:    .res 256
inodes:  .res 32*256
