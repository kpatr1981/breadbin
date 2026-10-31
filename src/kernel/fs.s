; Breadbin filesystem (c64fs): inodes, block maps, directories, path lookup
;
; All routines here run inside the (non-preemptible) kernel and never
; block, so they use non-swapped globals. Buffers returned by bread are
; only trusted until the next bread.
.include "k.inc"

.importzp bp
.import bwrite, bdirty, name_off

.segment "ZEROPAGE"
fb:     .res 2          ; caller buffer pointer for fs_read/fs_write
pp:     .res 2          ; path pointer for namei
.exportzp fb, pp

.segment "BSS"
; per-device superblock info (dev 0 = disk, 1 = REU)
sb_nblocks_lo: .res NDEV
sb_nblocks_hi: .res NDEV
sb_bitmap_lo:  .res NDEV
sb_bitmap_hi:  .res NDEV
sb_istart_lo:  .res NDEV
sb_istart_hi:  .res NDEV
sb_ninodes:    .res NDEV
sb_ok:         .res NDEV
sb_nblocks = sb_nblocks_lo
mnt_active: .res 1
mnt_ino:    .res 1      ; inode of /tmp on dev 0
; mount table: (mt_pdev, mt_pino) is the mount point, mt_dev the device
mt_used: .res NMNT
mt_pdev: .res NMNT
mt_pino: .res NMNT
mt_dev:  .res NMNT
mt_path: .res NMNT*32

ci:      .res INO_SIZE  ; working inode
ci_dev:  .res 1
ci_ino:  .res 1
fs_name: .res 16        ; path component, NUL-padded to 15
fs_name2: .res 16
nm_dev:  .res 1
nm_ino:  .res 1
nm_parent: .res 1
nm_last: .res 1
nm_y:    .res 1
f_off:   .res 3
f_cnt:   .res 2
f_done:  .res 2
f_buf = fb
bm_alloc: .res 1
bm_idx:  .res 1
bm_res:  .res 2
dl_pos:  .res 2
dl_off:  .res 2
dl_free: .res 2
dl_ino:  .res 1
ib_lo:   .res 1
ib_hi:   .res 1
io_n:    .res 1
io_w:    .res 1
cnt:     .res 2
tr_i:    .res 1
ba_dev:  .res 1

.export bm_alloc
.export sb_ok, fs_name2, nm_dev, nm_ino, dl_off, dl_ino, f_done, dir_put
.export bfree, mnt_active, mnt_ino, fs_count_inodes, sb_ninodes, ci_load_type
.export inode_blk, s_dot, s_dotdot, sb_nblocks_lo, sb_nblocks_hi
.export mt_used, mt_pdev, mt_pino, mt_dev, mt_path, mnt_point, mnt_of_dev, mount_dev
.import cbm_iget, cbm_lookup

.segment "RODATA"
magic:  .byte "C64FS"
s_dot:  .byte ".", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
s_dotdot: .byte "..", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
s_tmp:  .byte "tmp", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
s_tmpp: .byte "/tmp", 0

.segment "CODE"
; ---------------------------------------------------------------------
; fs_mount: mount dev 0 (and the REU RAM disk at /tmp if present)
fs_mount:
        lda #0
        ldx #<376
        ldy #>376
        jsr mount_dev
        bcs @r
        lda dev_present+1
        beq @ok
        jsr fs_mkfs_reu
        bcs @ok
        lda #1
        ldx #0
        ldy #0
        jsr mount_dev
        bcs @ok
        ; find /tmp on dev 0
        lda #0
        ldx #ROOT_INO
        jsr iget
        bcs @ok
        ldx #15
@c:     lda s_tmp,x
        sta fs_name,x
        dex
        bpl @c
        jsr dir_lookup
        beq @ok
        sta mnt_ino
        sta mt_pino
        lda #1
        sta mnt_active
        sta mt_used
        sta mt_dev
        lda #0
        sta mt_pdev
        ldx #4
@p:     lda s_tmpp,x
        sta mt_path,x
        dex
        bpl @p
@ok:    clc
@r:     rts

; mnt_point: A = dev, X = ino -> X = mount entry, carry clear if mounted on
mnt_point:
        sta tmp0
        stx tmp1
        ldx #NMNT-1
@l:     lda mt_used,x
        beq @n
        lda mt_pdev,x
        cmp tmp0
        bne @n
        lda mt_pino,x
        cmp tmp1
        beq @y
@n:     dex
        bpl @l
        sec
        rts
@y:     clc
        rts

; mnt_of_dev: A = dev -> X = mount entry, carry clear if mounted
mnt_of_dev:
        ldx #NMNT-1
@l:     ldy mt_used,x
        beq @n
        cmp mt_dev,x
        beq @y
@n:     dex
        bpl @l
        sec
        rts
@y:     clc
        rts

; mount_dev: A = dev, X/Y = superblock block
mount_dev:
        sta tmp3
        lda tmp3
        jsr bread
        bcs @r
        ldy #4
@m:     lda (bp),y
        cmp magic,y
        bne @bad
        dey
        bpl @m
        ldx tmp3
        ldy #6
        lda (bp),y
        sta sb_nblocks_lo,x
        iny
        lda (bp),y
        sta sb_nblocks_hi,x
        iny
        lda (bp),y
        sta sb_ninodes,x
        iny
        lda (bp),y
        sta sb_bitmap_lo,x
        iny
        lda (bp),y
        sta sb_bitmap_hi,x
        iny
        lda (bp),y
        sta sb_istart_lo,x
        iny
        lda (bp),y
        sta sb_istart_hi,x
        lda #1
        sta sb_ok,x
        clc
@r:     rts
@bad:   lda #EIO
        sec
        rts

; ---------------------------------------------------------------------
; inode_blk: A = dev, X = ino -> ib_lo/hi = block, Y = offset in block
inode_blk:
        sta tmp3
        txa
        lsr a
        lsr a
        lsr a
        ldx tmp3
        clc
        adc sb_istart_lo,x
        sta ib_lo
        lda sb_istart_hi,x
        adc #0
        sta ib_hi
        rts

; iget: A = dev, X = ino -> ci loaded
iget:
        sta ci_dev
        stx ci_ino
        tay
        lda dev_type,y
        beq @c64
        jmp cbm_iget
@c64:   lda ci_dev
        jsr inode_blk
        lda ci_dev
        ldx ib_lo
        ldy ib_hi
        jsr bread
        bcs @r
        lda ci_ino
        and #7
        asl a
        asl a
        asl a
        asl a
        asl a
        tay
        ldx #0
@l:     lda (bp),y
        sta ci,x
        iny
        inx
        cpx #INO_SIZE
        bne @l
        clc
@r:     rts

; iput: write ci back to its inode slot
iput:
        ldx ci_dev
        lda dev_type,x
        beq @c64
        clc                 ; CBM disks have no inodes to write
        rts
@c64:   lda ci_dev
        ldx ci_ino
        jsr inode_blk
        lda ci_dev
        ldx ib_lo
        ldy ib_hi
        jsr bread
        bcs @r
        stx tmp2
        lda ci_ino
        and #7
        asl a
        asl a
        asl a
        asl a
        asl a
        tay
        ldx #0
@l:     lda ci,x
        sta (bp),y
        iny
        inx
        cpx #INO_SIZE
        bne @l
        ldx tmp2
        jmp bdirty
@r:     rts

ci_load_type:
        lda ci+I_TYPE
        rts

; ialloc: A = dev, X = type -> A = new inode number, ci = that inode
ialloc:
        sta ba_dev
        stx tmp2
        ldx #1
@l:     stx tr_i
        lda ba_dev
        jsr iget
        bcs @r
        lda ci+I_TYPE
        beq @got
        ldx tr_i
        inx
        txa
        ldy ba_dev
        cmp sb_ninodes,y
        bcc @l
        lda #ENOSPC
        sec
@r:     rts
@got:   ldx #INO_SIZE-1
        lda #0
@z:     sta ci,x
        dex
        bpl @z
        lda tmp2
        sta ci+I_TYPE
        lda #1
        sta ci+I_NLINK
        jsr iput
        bcs @r
        lda ci_ino
        clc
        rts

; ---------------------------------------------------------------------
; bitmap
; balloc: allocate a zeroed block on ci_dev -> X/Y = block
balloc:
        ldx ci_dev
        stx ba_dev
        lda sb_bitmap_lo,x
        pha
        lda sb_bitmap_hi,x
        tay
        pla
        tax
        lda ba_dev
        jsr bread
        bcs @r
        stx tmp2            ; bitmap buffer index
        ldy #0
@l:     lda (bp),y
        cmp #$ff
        bne @byte
        iny
        bne @l
@full:  lda #ENOSPC
        sec
@r:     rts
@byte:  ldx #0
        sta tmp0
        lda #1
        sta tmp1
@bit:   lda tmp0
        and tmp1
        beq @free
        asl tmp1
        inx
        bne @bit
@free:  ; block = y*8 + x
        stx bm_res
        tya
        sta bm_res+1
        lda #0
        asl bm_res+1        ; we compute (y << 3) | x in bm_res lo/hi
        rol a
        asl bm_res+1
        rol a
        asl bm_res+1
        rol a
        sta tmp0            ; hi
        lda bm_res+1
        ora bm_res
        sta bm_res
        lda tmp0
        sta bm_res+1
        ; range check
        ldx ba_dev
        lda bm_res+1
        cmp sb_nblocks_hi,x
        bcc @inr
        bne @full
        lda bm_res
        cmp sb_nblocks_lo,x
        bcs @full
@inr:   lda (bp),y
        ora tmp1
        sta (bp),y
        ldx tmp2
        jsr bdirty
        bcs @r
        lda ba_dev
        ldx bm_res
        ldy bm_res+1
        jsr bget_buf
        jsr bdirty
        bcs @r
        ldx bm_res
        ldy bm_res+1
        clc
        rts

; bfree: X/Y = block on ci_dev
bfree:
        stx bm_res
        sty bm_res+1
        ldx ci_dev
        stx ba_dev
        lda sb_bitmap_lo,x
        pha
        lda sb_bitmap_hi,x
        tay
        pla
        tax
        lda ba_dev
        jsr bread
        bcs @r
        stx tmp2
        lda bm_res
        and #7
        tax
        lda #1
@s:     dex
        bmi @m
        asl a
        jmp @s
@m:     eor #$ff
        sta tmp0
        ; byte index = block >> 3
        lda bm_res+1
        sta tmp1
        lda bm_res
        lsr tmp1
        ror a
        lsr tmp1
        ror a
        lsr tmp1
        ror a
        tay
        lda (bp),y
        and tmp0
        sta (bp),y
        ldx tmp2
        jmp bdirty
@r:     rts

; fs_count_free: A = dev -> X/Y = free blocks
fs_count_free:
        sta ba_dev
        tax
        lda #0
        sta cnt
        sta cnt+1
        lda sb_bitmap_lo,x
        pha
        lda sb_bitmap_hi,x
        tay
        pla
        tax
        lda ba_dev
        jsr bread
        bcs @r
        ldy #0
@l:     lda (bp),y
        ldx #8
@b:     lsr a
        bcs @u
        inc cnt
        bne @u
        inc cnt+1
@u:     dex
        bne @b
        iny
        bne @l
        ldx cnt
        ldy cnt+1
        clc
@r:     rts

; fs_count_inodes: A = dev -> X = free inodes
fs_count_inodes:
        sta ba_dev
        lda #0
        sta cnt
        ldx #1
@l:     stx tr_i
        lda ba_dev
        jsr iget
        bcs @r
        lda ci+I_TYPE
        bne @n
        inc cnt
@n:     ldx tr_i
        inx
        txa
        ldy ba_dev
        cmp sb_ninodes,y
        bcc @l
        ldx cnt
        clc
@r:     rts

; ---------------------------------------------------------------------
; bmap: A = file block index, bm_alloc = allocate if missing.
; -> X/Y = block (0 = hole). Uses/modifies ci (caller must iput).
bmap:
        sta bm_idx
        cmp #NDIRECT
        bcs @ind
        asl a
        adc #I_DIRECT
        tax
        stx tmp3
        lda ci,x
        ora ci+1,x
        bne @have
        lda bm_alloc
        beq @zero
        jsr balloc
        bcs @r
        txa
        ldx tmp3
        sta ci,x
        tya
        sta ci+1,x
@have:  lda ci+1,x
        tay
        lda ci,x
        tax
        clc
@r:     rts
@zero:  ldx #0
        ldy #0
        clc
        rts
@ind:   sec
        sbc #NDIRECT
        bmi @big
        sta bm_idx
        lda ci+I_INDIR
        ora ci+I_INDIR+1
        bne @hasind
        lda bm_alloc
        beq @zero
        jsr balloc
        bcs @r
        stx ci+I_INDIR
        sty ci+I_INDIR+1
@hasind:
        jsr read_ind
        bcs @r
        lda (bp),y
        iny
        ora (bp),y
        bne @ihave
        lda bm_alloc
        beq @zero
        jsr balloc
        bcs @r
        stx bm_res
        sty bm_res+1
        jsr read_ind
        bcs @r
        stx tmp2
        lda bm_res
        sta (bp),y
        iny
        lda bm_res+1
        sta (bp),y
        ldx tmp2
        jsr bdirty
        bcs @r
        ldx bm_res
        ldy bm_res+1
        clc
        rts
@ihave: lda (bp),y
        pha
        dey
        lda (bp),y
        tax
        pla
        tay
        clc
        rts
@big:   lda #EFBIG
        sec
        rts

; read_ind: bread the indirect block of ci; Y = 2*bm_idx
read_ind:
        lda bm_idx
        cmp #128
        bcs @big
        lda ci_dev
        ldx ci+I_INDIR
        ldy ci+I_INDIR+1
        jsr bread
        bcs @r
        lda bm_idx
        asl a
        tay
        clc
@r:     rts
@big:   lda #EFBIG
        sec
        rts

; itrunc: free all blocks of ci, size = 0 (caller iputs)
itrunc:
        ldx #0
@d:     stx tr_i
        lda ci+I_DIRECT,x
        ora ci+I_DIRECT+1,x
        beq @dn
        lda ci+I_DIRECT+1,x
        tay
        lda ci+I_DIRECT,x
        pha
        lda #0
        sta ci+I_DIRECT,x
        sta ci+I_DIRECT+1,x
        pla
        tax
        jsr bfree
@dn:    ldx tr_i
        inx
        inx
        cpx #NDIRECT*2
        bne @d
        lda ci+I_INDIR
        ora ci+I_INDIR+1
        beq @done
        lda #0
@i:     sta bm_idx
        jsr read_ind
        bcs @done
        lda (bp),y
        tax
        iny
        lda (bp),y
        tay
        txa
        bne @f
        tya
        beq @in
@f:     jsr bfree
@in:    inc bm_idx
        lda bm_idx
        cmp #128
        bne @i
        ldx ci+I_INDIR
        ldy ci+I_INDIR+1
        jsr bfree
        lda #0
        sta ci+I_INDIR
        sta ci+I_INDIR+1
@done:  lda #0
        sta ci+I_SIZE
        sta ci+I_SIZE+1
        sta ci+I_SIZE+2
        clc
        rts

; ---------------------------------------------------------------------
; io_lim: io_n = min(io_n, A) where 0 means 256 for both
io_lim:
        cmp #0
        beq @r
        ldx io_n
        beq @set
        cmp io_n
        bcs @r
@set:   sta io_n
@r:     rts

; io_lim_cnt: io_n = min(io_n, f_cnt)
io_lim_cnt:
        lda f_cnt+1
        bne @r
        lda f_cnt
        jmp io_lim
@r:     rts

; fs_read: from ci at f_off, up to f_cnt bytes into (fb).
; -> f_done = bytes read, f_off advanced
fs_read:
        lda #0
        sta f_done
        sta f_done+1
        sta bm_alloc
@loop:  lda f_cnt
        ora f_cnt+1
        bne @go
        jmp @end
@go:    ; remaining in file = size - off
        lda ci+I_SIZE
        sec
        sbc f_off
        sta cnt
        lda ci+I_SIZE+1
        sbc f_off+1
        sta cnt+1
        lda ci+I_SIZE+2
        sbc f_off+2
        bcc @end0
        bne @big
        lda cnt+1
        bne @big
        lda cnt
        bne @some
@end0:  jmp @end
@some:  sta io_n
        jmp @lim
@big:   lda #0              ; 256
        sta io_n
@lim:   lda f_off
        eor #$ff
        clc
        adc #1              ; 256 - off_lo (0 = 256)
        jsr io_lim
        jsr io_lim_cnt
        lda f_off+1
        jsr bmap
        bcs @r
        txa
        bne @rd
        tya
        bne @rd
        ldy #0              ; hole: zeros
        tya
@hz:    sta (fb),y
        iny
        cpy io_n
        bne @hz
        jmp @adv
@rd:    lda ci_dev
        jsr bread
        bcs @r
        ldx f_off
        ldy #0
@cp:    sty tmp1
        txa
        tay
        lda (bp),y
        ldy tmp1
        sta (fb),y
        inx
        iny
        cpy io_n
        bne @cp
@adv:   jsr io_advance
        jmp @loop
@end:   clc
@r:     rts

; advance f_off, fb, f_done by io_n (0 = 256); f_cnt -= io_n
io_advance:
        lda io_n
        beq @page
        clc
        adc f_off
        sta f_off
        bcc @a
        inc f_off+1
        bne @a
        inc f_off+2
@a:     lda fb
        clc
        adc io_n
        sta fb
        bcc @b
        inc fb+1
@b:     lda f_done
        clc
        adc io_n
        sta f_done
        bcc @c
        inc f_done+1
@c:     lda f_cnt
        sec
        sbc io_n
        sta f_cnt
        bcs @d
        dec f_cnt+1
@d:     rts
@page:  inc f_off+1
        bne @p1
        inc f_off+2
@p1:    inc fb+1
        inc f_done+1
        dec f_cnt+1
        rts

; fs_write: f_cnt bytes from (fb) to ci at f_off; extends size. iputs.
fs_write:
        lda #0
        sta f_done
        sta f_done+1
        lda #1
        sta bm_alloc
@loop:  lda f_cnt
        ora f_cnt+1
        bne @go
        jmp @end
@go:    lda f_off
        eor #$ff
        clc
        adc #1
        sta io_n            ; 256 - off_lo (0 = 256)
        jsr io_lim_cnt
        lda f_off+2
        bne @fbig
        lda f_off+1
        cmp #NDIRECT+128
        bcs @fbig
        lda #1
        sta bm_alloc
        lda f_off+1
        jsr bmap
        bcs @err
        lda ci_dev
        jsr bread
        bcs @err
        stx io_w
        ldx f_off
        ldy #0
@cp:    sty tmp1
        lda (fb),y
        stx tmp0
        ldy tmp0
        sta (bp),y
        ldy tmp1
        inx
        iny
        cpy io_n
        bne @cp
        ldx io_w
        jsr bdirty
        bcs @err
        jsr io_advance
        ; size = max(size, off)
        lda ci+I_SIZE
        cmp f_off
        lda ci+I_SIZE+1
        sbc f_off+1
        lda ci+I_SIZE+2
        sbc f_off+2
        bcs @loop
        lda f_off
        sta ci+I_SIZE
        lda f_off+1
        sta ci+I_SIZE+1
        lda f_off+2
        sta ci+I_SIZE+2
        jmp @loop
@fbig:  lda #EFBIG
@err:   pha
        jsr iput
        pla
        ldx f_done
        bne @part
        ldx f_done+1
        bne @part
        sec                 ; nothing written: report the error
        rts
@part:  clc
        rts
@end:   jmp iput

; ---------------------------------------------------------------------
; directories (ci = directory inode, fs_name = 15-byte padded name)
;
; dir_lookup -> A = inode (Z set if not found); dl_off = entry offset,
; dl_free = first free entry offset ($ffff if none)
dir_lookup:
        ldx ci_dev
        lda dev_type,x
        beq @c64
        jmp cbm_lookup
@c64:   lda #0
        sta dl_pos
        sta dl_pos+1
        sta bm_alloc
        lda #$ff
        sta dl_free
        sta dl_free+1
@loop:  lda dl_pos
        cmp ci+I_SIZE
        lda dl_pos+1
        sbc ci+I_SIZE+1
        bcs @none
        lda dl_pos
        bne @have
        lda dl_pos+1
        jsr bmap
        bcs @none
        lda ci_dev
        jsr bread
        bcs @none
@have:  ldy dl_pos
        lda (bp),y
        bne @cmp
        lda dl_free+1
        cmp #$ff
        bne @next
        lda dl_pos
        sta dl_free
        lda dl_pos+1
        sta dl_free+1
        jmp @next
@cmp:   sta dl_ino
        ldx #0
@c:     iny
        lda (bp),y
        cmp fs_name,x
        bne @next
        inx
        cpx #15
        bne @c
        lda dl_pos
        sta dl_off
        lda dl_pos+1
        sta dl_off+1
        lda dl_ino
        rts
@next:  lda dl_pos
        clc
        adc #DIRENT
        sta dl_pos
        bcc @loop
        inc dl_pos+1
        jmp @loop
@none:  lda #0
        rts

; dir_put: write inode A (0 = remove) at entry dl_off of ci, with fs_name
dir_put:
        sta dl_ino
        lda #0
        sta bm_alloc
        lda dl_off+1
        jsr bmap
        bcs @r
        lda ci_dev
        jsr bread
        bcs @r
        stx io_w
        ldy dl_off
        lda dl_ino
        sta (bp),y
        ldx #0
@n:     iny
        lda fs_name,x
        sta (bp),y
        inx
        cpx #15
        bne @n
        ldx io_w
        jmp bdirty
@r:     rts

; dir_add: add entry fs_name -> inode A to directory ci
dir_add:
        pha
        jsr dir_lookup
        lda dl_free+1
        cmp #$ff
        beq @append
        lda dl_free
        sta dl_off
        lda dl_free+1
        sta dl_off+1
        pla
        jmp dir_put
@append:
        lda ci+I_SIZE
        sta dl_off
        lda ci+I_SIZE+1
        sta dl_off+1
        lda dl_off
        bne @noblk
        lda #1
        sta bm_alloc
        lda dl_off+1
        jsr bmap
        bcs @err
@noblk: lda ci+I_SIZE
        clc
        adc #DIRENT
        sta ci+I_SIZE
        bcc @s
        inc ci+I_SIZE+1
@s:     jsr iput
        bcs @err
        pla
        jmp dir_put
@err:   tax
        pla
        txa
        sec
        rts

; dir_remove: remove fs_name from ci -> carry set if not found
dir_remove:
        jsr dir_lookup
        bne @f
        lda #ENOENT
        sec
        rts
@f:     lda #0
        jmp dir_put

; dir_empty: Z set (A=0) if ci has nothing but . and ..
dir_empty:
        lda #0
        sta dl_pos
        sta dl_pos+1
        sta bm_alloc
@loop:  lda dl_pos
        cmp ci+I_SIZE
        lda dl_pos+1
        sbc ci+I_SIZE+1
        bcs @yes
        lda dl_pos
        bne @have
        lda dl_pos+1
        jsr bmap
        bcs @yes
        lda ci_dev
        jsr bread
        bcs @yes
@have:  ldy dl_pos
        lda (bp),y
        beq @next
        iny
        lda (bp),y
        cmp #'.'
        bne @no
        iny
        lda (bp),y
        beq @next
        cmp #'.'
        bne @no
        iny
        lda (bp),y
        bne @no
@next:  lda dl_pos
        clc
        adc #DIRENT
        sta dl_pos
        bcc @loop
        inc dl_pos+1
        jmp @loop
@yes:   lda #0
        rts
@no:    lda #1
        rts

; ---------------------------------------------------------------------
; namei: pp = path. nm_parent = 0: resolve whole path -> nm_dev/nm_ino.
; nm_parent = 1: stop at the last component -> nm_dev/nm_ino = parent
; directory, fs_name = last component.
namei:
        ldy #0
        lda (pp),y
        bne @ne
        lda #ENOENT
        sec
        rts
@ne:    cmp #'/'
        bne @rel
        lda #0
        sta nm_dev
        lda #ROOT_INO
        sta nm_ino
        jmp @loop
@rel:   ldx cur
        lda p_cwddev,x
        sta nm_dev
        lda p_cwdino,x
        sta nm_ino
@loop:  ; skip slashes
        lda (pp),y
        cmp #'/'
        bne @ns
        iny
        bne @loop
@ns:    lda (pp),y
        bne @comp
        ; end of path
        lda nm_parent
        beq @done
        ; parent requested but no component (path "/" or "")
        lda #EINVAL
        sec
        rts
@done:  clc
        rts
@comp:  ; copy component into fs_name
        ldx #0
@cc:    lda (pp),y
        beq @ce
        cmp #'/'
        beq @ce
        cpx #NAME_MAX
        bcs @long
        sta fs_name,x
        inx
        iny
        bne @cc
@long:  lda #ENAMETOOLONG
        sec
        rts
@ce:    lda #0
@pad:   cpx #16
        bcs @pd
        sta fs_name,x
        inx
        bne @pad
@pd:    ; is this the last component?
        sty tmp2
@sk:    lda (pp),y
        cmp #'/'
        bne @sk2
        iny
        bne @sk
@sk2:   sta nm_last         ; 0 if last
        ldy tmp2
        lda nm_last
        bne @lookup
        lda nm_parent
        beq @lookup
        clc                 ; stop: parent dir + fs_name
        rts
@lookup:
        sty nm_y
        lda nm_dev
        ldx nm_ino
        jsr iget
        bcs @r
        lda ci+I_TYPE
        cmp #T_DIR
        beq @isdir
        lda #ENOTDIR
        sec
        rts
@isdir: ; ".." from the root of a mounted fs goes to its mount point
        lda nm_dev
        beq @lk
        lda nm_ino
        cmp #ROOT_INO
        bne @lk
        lda fs_name
        cmp #'.'
        bne @lk
        lda fs_name+1
        cmp #'.'
        bne @lk
        lda fs_name+2
        bne @lk
        lda nm_dev
        jsr mnt_of_dev
        bcs @lk
        lda mt_pdev,x
        sta nm_dev
        lda mt_pino,x
        sta nm_ino
        tax
        lda nm_dev
        jsr iget
        bcs @r
@lk:    jsr dir_lookup
        bne @found
        lda #ENOENT
        sec
@r:     rts
@found: sta nm_ino
        ; crossing into a mount point?
        lda nm_dev
        ldx nm_ino
        jsr mnt_point
        bcs @nx
        lda mt_dev,x
        sta nm_dev
        lda #ROOT_INO
        sta nm_ino
@nx:    ldy nm_y
        jmp @loop

; nameiparent: = namei with nm_parent set
nameiparent:
        lda #1
        sta nm_parent
        jsr namei
        php
        pha
        lda #0
        sta nm_parent
        pla
        plp
        bcs @r
        lda nm_dev
        ldx nm_ino
        jsr iget
        bcs @r
        lda ci+I_TYPE
        cmp #T_DIR
        beq @ok
        lda #ENOTDIR
        sec
        rts
@ok:    clc
@r:     rts

; ---------------------------------------------------------------------
; fs_mkfs_reu: format the REU as c64fs (superblock 0, bitmap 1, inodes 2-17)
fs_mkfs_reu:
        lda #1
        sta ci_dev
        ; nblocks = min(banks*256, 2048)
        lda reu_banks
        cmp #8
        bcc @s
        lda #8
@s:     sta sb_nblocks_hi+1
        lda #0
        sta sb_nblocks_lo+1
        ; superblock
        lda #1
        ldx #0
        ldy #0
        jsr bget_buf
        stx io_w
        ldy #4
@m:     lda magic,y
        sta (bp),y
        dey
        bpl @m
        ldy #5
        lda #1
        sta (bp),y
        iny
        lda #0
        sta (bp),y          ; nblocks lo
        iny
        lda sb_nblocks_hi+1
        sta (bp),y
        iny
        lda #128
        sta (bp),y
        iny
        lda #1              ; bitmap block 1
        sta (bp),y
        iny
        lda #0
        sta (bp),y
        iny
        lda #2              ; inode start 2
        sta (bp),y
        iny
        lda #0
        sta (bp),y
        iny
        lda #16
        sta (bp),y
        iny
        lda #ROOT_INO
        sta (bp),y
        ldx io_w
        jsr bwrite
        ; bitmap: blocks 0-17 used, bits past nblocks used
        lda #1
        ldx #1
        ldy #0
        jsr bget_buf
        stx io_w
        ldy #0
        lda #$ff
        sta (bp),y
        iny
        sta (bp),y
        iny
        lda #$03
        sta (bp),y
        ; bytes from nblocks/8 to 255 = $ff
        lda sb_nblocks_hi+1
        asl a
        asl a
        asl a
        asl a
        asl a
        beq @bmdone         ; 8 banks -> 2048 blocks, nothing past end
        tay
        lda #$ff
@bf:    sta (bp),y
        iny
        bne @bf
@bmdone:
        ldx io_w
        jsr bwrite
        ; inode blocks
        lda #2
        sta tr_i
@ib:    lda #1
        ldx tr_i
        ldy #0
        jsr bget_buf
        lda tr_i
        cmp #2
        bne @ibw
        ldy #0
        lda #$ff            ; inode 0 is reserved
        sta (bp),y
@ibw:   jsr bwrite
        inc tr_i
        lda tr_i
        cmp #18
        bne @ib
        ; temporary mount info so the helpers below work
        lda #1
        sta sb_bitmap_lo+1
        lda #0
        sta sb_bitmap_hi+1
        sta sb_istart_hi+1
        lda #2
        sta sb_istart_lo+1
        lda #128
        sta sb_ninodes+1
        ; root directory
        lda #1
        ldx #T_DIR
        jsr ialloc
        bcs @r
        lda #2
        sta ci+I_NLINK
        ldx #15
@d1:    lda s_dot,x
        sta fs_name,x
        dex
        bpl @d1
        lda #ROOT_INO
        jsr dir_add
        bcs @r
        ldx #15
@d2:    lda s_dotdot,x
        sta fs_name,x
        dex
        bpl @d2
        lda #ROOT_INO
        jsr dir_add
@r:     rts
