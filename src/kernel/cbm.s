; Breadbin: normal Commodore DOS disks on drives 9-11, and mount()
;
; A CBM disk mounted with mount() shows up as one flat directory.
; Reading uses raw sectors through the block cache: the directory chain
; on track 18 and each file's track/sector chain. Writing, scratching
; and renaming go through the drive's own DOS (so its BAM stays right);
; afterwards the cache for that drive is dropped.
;
; Pseudo inodes: 1 = the root directory, k+2 = directory entry k.
.include "k.inc"

.importzp bp, pp
.import binval, cmdbuf, cmdlen, to_ascii, to_petscii, build_path, pbuf
.import mt_used, mt_pdev, mt_pino, mt_dev, mt_path, mnt_point, mount_dev
.import nm_dev, nm_ino, f_done

.export cbm_iget, cbm_lookup, cbm_read, cbm_readdir, cbm_open_write
.export cbm_write, cbm_wclose, cbm_scratch, cbm_rename, cbm_fsinfo
.export sys_mount, sys_umount, sys_mntinfo, sys_diskio

.segment "BSS"
cb_t:    .res 1
cb_s:    .res 1
cb_k:    .res 1
cb_e:    .res 1
cb_n:    .res 2         ; bytes copied
cb_lim:  .res 1         ; last valid offset + 1 in this sector (0 = 256)
cb_cnt:  .res 1
nbuf:    .res 16
w_busy:  .res NDEV
mo_dev:  .res 1
mo_pdev: .res 1
mo_pino: .res 1
mo_ent:  .res 1

.segment "RODATA"
magic:   .byte "C64FS"

.segment "CODE"
; ---------------------------------------------------------------------
; dir_entry: A = k -> bp/Y = that 32-byte entry; carry set if past the end
dir_entry:
        sta cb_k
        lda #18
        sta cb_t
        lda #1
        sta cb_s
        lda cb_k
        lsr a
        lsr a
        lsr a
        sta cb_cnt          ; sectors to skip
@w:     jsr rd_sec
        bcs @r
        lda cb_cnt
        beq @here
        dec cb_cnt
        ldy #0
        lda (bp),y
        beq @end
        sta cb_t
        iny
        lda (bp),y
        sta cb_s
        jmp @w
@here:  lda cb_k
        and #7
        asl a
        asl a
        asl a
        asl a
        asl a
        tay
        clc
        rts
@end:   sec
@r:     rts

; rd_sec: read sector cb_t/cb_s of ci_dev -> bp
rd_sec: lda cb_t
        ldx cb_s
        jsr ts_block
        lda ci_dev
        jmp bread

; valid: entry at bp/Y is a closed SEQ, PRG or USR file -> carry clear
valid:  sty tmp1
        iny
        iny
        lda (bp),y
        ldy tmp1
        tax
        bpl @no
        txa
        and #7
        beq @no
        cmp #4
        bcs @no
        clc
        rts
@no:    sec
        rts

; name_of: entry at bp/Y -> nbuf (ASCII, NUL-padded to 16, max 14 chars)
name_of:
        ldx #0
@l:     lda #0
        cpx #NAME_MAX
        bcs @z
        sty tmp1
        tya
        clc
        adc #5
        stx tmp0
        adc tmp0
        tay
        lda (bp),y
        ldy tmp1
        cmp #$a0
        bne @cv
        lda #0
        beq @z
@cv:    jsr to_ascii
        bne @z
        lda #'?'
@z:     sta nbuf,x
        inx
        cpx #16
        bne @l
        ; stop at the first padding byte
        ldx #0
@s:     lda nbuf,x
        beq @pad
        inx
        cpx #16
        bne @s
        rts
@pad:   lda #0
@p:     sta nbuf,x
        inx
        cpx #16
        bne @p
        rts

; cbm_iget: ci_dev/ci_ino set -> ci synthesized from the directory
cbm_iget:
        ldx #INO_SIZE-1
        lda #0
@z:     sta ci,x
        dex
        bpl @z
        lda #1
        sta ci+I_NLINK
        lda ci_ino
        cmp #ROOT_INO
        bne @file
        lda #T_DIR
        sta ci+I_TYPE
        clc
        rts
@file:  sec
        sbc #2
        jsr dir_entry
        bcs @noent
        jsr valid
        bcs @noent
        lda #T_FILE
        sta ci+I_TYPE
        iny
        iny
        iny
        lda (bp),y          ; first track
        sta ci+I_DIRECT
        iny
        lda (bp),y          ; first sector
        sta ci+I_DIRECT+1
        ; size ~ blocks * 254 = blocks*256 - blocks*2
        tya
        clc
        adc #26
        tay
        lda (bp),y
        sta tmp0            ; blocks lo
        iny
        lda (bp),y
        sta tmp1            ; blocks hi
        lda #0
        sta ci+I_SIZE
        lda tmp0
        sta ci+I_SIZE+1
        lda tmp1
        sta ci+I_SIZE+2
        asl tmp0
        rol tmp1            ; blocks*2 (fits: < 1366)
        lda ci+I_SIZE
        sec
        sbc tmp0
        sta ci+I_SIZE
        lda ci+I_SIZE+1
        sbc tmp1
        sta ci+I_SIZE+1
        lda ci+I_SIZE+2
        sbc #0
        sta ci+I_SIZE+2
        clc
        rts
@noent: lda #ENOENT
        sec
        rts

; cbm_lookup: ci = root, fs_name -> A = pseudo inode (Z set if none)
cbm_lookup:
        lda #0
        sta cb_k
        lda #18
        sta cb_t
        lda #1
        sta cb_s
@sec:   jsr rd_sec
        bcs @none
        lda #0
        sta cb_e
@ent:   lda cb_e
        asl a
        asl a
        asl a
        asl a
        asl a
        tay
        jsr valid
        bcs @next
        jsr name_of
        ldx #0
@c:     lda nbuf,x
        cmp fs_name,x
        bne @next
        inx
        cpx #15
        bne @c
        lda cb_k
        clc
        adc #2
        rts
@next:  inc cb_k
        inc cb_e
        lda cb_e
        cmp #8
        bne @ent
        ldy #0
        lda (bp),y
        beq @none
        sta cb_t
        iny
        lda (bp),y
        sta cb_s
        jmp @sec
@none:  lda #0
        rts

; ---------------------------------------------------------------------
; cbm_read: open-file entry sb6 (t/s/offset in f_pos0/1/2, t = 0 at EOF),
; r0 = buffer, r1 = count -> r1 = bytes read
cbm_read:
        lda #0
        sta cb_n
        sta cb_n+1
        ldx sb6
        lda f_dev,x
        sta ci_dev
@loop:  lda cb_n
        cmp r1
        lda cb_n+1
        sbc r1+1
        bcc *+5
        jmp @done
        ldx sb6
        lda f_pos0,x
        bne *+5
        jmp @done
        sta cb_t
        lda f_pos1,x
        sta cb_s
        jsr rd_sec
        bcs @done
        ldy #0
        lda (bp),y
        bne @full
        iny
        lda (bp),y
        clc
        adc #1              ; last sector: valid up to link_s
        jmp @lim
@full:  lda #0              ; 256
@lim:   sta cb_lim
        ldx sb6
        lda f_pos2,x
        cmp cb_lim
        bne @copy
        ; sector used up: follow the link
        ldy #0
        lda (bp),y
        sta f_pos0,x
        iny
        lda (bp),y
        sta f_pos1,x
        lda #2
        sta f_pos2,x
        jmp @loop
@copy:  ; one byte at a time (the 1541 is the bottleneck, not this loop)
        tay
        lda (bp),y
        pha
        lda r0
        clc
        adc cb_n
        sta p1
        lda r0+1
        adc cb_n+1
        sta p1+1
        pla
        ldy #0
        sta (p1),y
        inc cb_n
        bne @i
        inc cb_n+1
@i:     ldx sb6
        inc f_pos2,x
        lda f_pos2,x
        cmp cb_lim
        bne @copy2
        jmp @loop
@copy2: ; keep copying from the same sector while there is room
        lda cb_n
        cmp r1
        lda cb_n+1
        sbc r1+1
        bcs @done
        lda f_pos2,x
        jmp @copy
@done:  lda cb_n
        sta r1
        lda cb_n+1
        sta r1+1
        clc
        rts

; cbm_readdir: open-file entry sb6 (dir t/s/entry in f_pos0/1/2, k in
; f_pipe) -> 16-byte entries {ino, name[15]} into r0, up to r1 bytes
cbm_readdir:
        lda #0
        sta cb_n
        sta cb_n+1
        ldx sb6
        lda f_dev,x
        sta ci_dev
@loop:  lda cb_n
        clc
        adc #16
        tay
        lda cb_n+1
        adc #0
        cmp r1+1
        bcc @room
        beq *+5
        jmp @done
        cpy r1
        beq @room
        bcc *+5
        jmp @done
@room:  ldx sb6
        lda f_pos0,x
        bne *+5
        jmp @done
        sta cb_t
        lda f_pos1,x
        sta cb_s
        jsr rd_sec
        bcs @done
        ldx sb6
        lda f_pos2,x
        asl a
        asl a
        asl a
        asl a
        asl a
        tay
        sty cb_e
        jsr valid
        bcs @skip
        ldy cb_e
        jsr name_of
        ; emit {k+2, name}
        lda r0
        clc
        adc cb_n
        sta p1
        lda r0+1
        adc cb_n+1
        sta p1+1
        ldx sb6
        lda f_pipe,x
        clc
        adc #2
        ldy #0
        sta (p1),y
        ldx #0
@cp:    lda nbuf,x
        iny
        sta (p1),y
        inx
        cpx #15
        bne @cp
        lda cb_n
        clc
        adc #16
        sta cb_n
        bcc @skip
        inc cb_n+1
@skip:  ldx sb6
        inc f_pipe,x
        inc f_pos2,x
        lda f_pos2,x
        cmp #8
        beq *+5
        jmp @loop
        lda #0
        sta f_pos2,x
        ldy #0
        lda (bp),y
        sta f_pos0,x
        iny
        lda (bp),y
        sta f_pos1,x
        jmp @loop
@done:  lda cb_n
        sta r1
        lda cb_n+1
        sta r1+1
        clc
        rts

; ---------------------------------------------------------------------
; DOS commands
; cmd_name: append fs_name (as PETSCII) to cmdbuf
cmd_name:
        ldx #0
@l:     lda fs_name,x
        beq @r
        jsr to_petscii
        ldy cmdlen
        sta cmdbuf,y
        inc cmdlen
        inx
        cpx #15
        bne @l
@r:     rts

cmd_str:                    ; append the 0-terminated string at p1
        ldy #0
@l:     lda (p1),y
        beq @r
        ldx cmdlen
        sta cmdbuf,x
        inc cmdlen
        iny
        bne @l
@r:     rts

; cbm_scratch: A = dev, fs_name = file
cbm_scratch:
        pha
        lda #0
        sta cmdlen
        lda #<s_scr
        sta p1
        lda #>s_scr
        sta p1+1
        jsr cmd_str
        jsr cmd_name
        pla
        pha
        jsr iec_command
        pla
        php
        jsr binval
        plp
        bcc @r
        lda #EIO
@r:     rts

; cbm_rename: A = dev, fs_name2 = old, fs_name = new
.import fs_name2
cbm_rename:
        pha
        lda #0
        sta cmdlen
        lda #<s_ren
        sta p1
        lda #>s_ren
        sta p1+1
        jsr cmd_str
        jsr cmd_name
        lda #'='
        ldx cmdlen
        sta cmdbuf,x
        inc cmdlen
        ; old name
        ldx #0
@l:     lda fs_name2,x
        beq @e
        jsr to_petscii
        ldy cmdlen
        sta cmdbuf,y
        inc cmdlen
        inx
        cpx #15
        bne @l
@e:     pla
        pha
        jsr iec_command
        pla
        php
        jsr binval
        plp
        bcc @r
        lda #EIO
@r:     rts

; cbm_open_write: A = dev, fs_name = file -> A = logical file number
; (replaces an existing file of that name)
cbm_open_write:
        sta mo_dev
        tax
        lda w_busy,x
        beq @free
        lda #EMFILE
        sec
        rts
@free:  lda mo_dev
        jsr cbm_scratch
        ; "0:name,s,w"
        lda #0
        sta cmdlen
        lda #<s_w0
        sta p1
        lda #>s_w0
        sta p1+1
        jsr cmd_str
        jsr cmd_name
        lda #<s_w1
        sta p1
        lda #>s_w1
        sta p1+1
        jsr cmd_str
        lda cmdlen
        ldx #<cmdbuf
        ldy #>cmdbuf
        jsr SETNAM
        ldx mo_dev
        lda dev_drive,x
        tax
        lda mo_dev
        clc
        adc #20             ; logical file 20+dev, secondary address 3
        ldy #3
        jsr SETLFS
        jsr OPEN
        bcs @err
        lda mo_dev
        .import iec_status
        jsr iec_status
        bcs @err2
        ldx mo_dev
        lda #1
        sta w_busy,x
        lda mo_dev
        clc
        adc #20
        clc
        rts
@err2:  lda mo_dev
        clc
        adc #20
        jsr CLOSE
@err:   jsr CLRCHN
        lda mo_dev
        jsr binval
        lda #EIO
        sec
        rts

; cbm_write: entry sb6 (f_pipe = lfn), r0/r1 -> r1 written
cbm_write:
        ldx sb6
        lda f_pipe,x
        tax
        jsr CHKOUT
        bcs @e
        lda r0
        sta p1
        lda r0+1
        sta p1+1
        lda r1
        sta cb_n
        lda r1+1
        sta cb_n+1
@l:     lda cb_n
        ora cb_n+1
        beq @d
        ldy #0
        lda (p1),y
        jsr CHROUT
        inc p1
        bne @c
        inc p1+1
@c:     lda cb_n
        bne @dl
        dec cb_n+1
@dl:    dec cb_n
        jmp @l
@d:     jsr CLRCHN
        clc
        rts
@e:     jsr CLRCHN
        lda #EIO
        sec
        rts

; cbm_wclose: A = lfn (20+dev). Finish the DOS file.
cbm_wclose:
        pha
        jsr CLOSE
        jsr CLRCHN
        pla
        sec
        sbc #20
        tax
        lda #0
        sta w_busy,x
        txa
        jmp binval

; cbm_fsinfo: A = dev -> X/Y = free blocks (from the BAM)
cbm_fsinfo:
        sta ci_dev
        lda #18
        sta cb_t
        lda #0
        sta cb_s
        jsr rd_sec
        bcs @r
        lda #0
        sta cb_n
        sta cb_n+1
        ldy #4
@l:     cpy #4*18           ; skip the directory track
        beq @n
        lda (bp),y
        clc
        adc cb_n
        sta cb_n
        bcc @n
        inc cb_n+1
@n:     iny
        iny
        iny
        iny
        cpy #4*36
        bne @l
        ldx cb_n
        ldy cb_n+1
        clc
@r:     rts

; ---------------------------------------------------------------------
; mount(A = drive 9-11, r0 = directory)
sys_mount:
        sec
        sbc #7
        cmp #2
        bcc @inval
        cmp #NDEV
        bcs @inval
        sta mo_dev
        tax
        lda dev_present,x
        beq @np
        lda #EBUSY
        sec
        rts
@inval: lda #EINVAL
        sec
        rts
@np:    ; free mount entry
        ldx #NMNT-1
@fe:    lda mt_used,x
        beq @got
        dex
        bpl @fe
        lda #EBUSY
        sec
        rts
@got:   stx mo_ent
        lda r0
        sta pp
        lda r0+1
        sta pp+1
        jsr namei
        bcs @r
        lda nm_dev
        sta mo_pdev
        lda nm_ino
        sta mo_pino
        lda nm_dev
        ldx nm_ino
        jsr iget
        bcs @r
        lda ci+I_TYPE
        cmp #T_DIR
        beq @dir
        lda #ENOTDIR
        sec
@r:     rts
@dir:   lda mo_pino         ; not on top of another mount
        cmp #ROOT_INO
        bne @nr
        lda mo_pdev
        bne @busy
@nr:    lda mo_pdev
        ldx mo_pino
        jsr mnt_point
        bcs @ok
@busy:  lda #EBUSY
        sec
        rts
@ok:    jsr build_path
        bcs @r
        ldx mo_dev
        jsr iec_open
        bcs @r
        lda mo_dev
        jsr binval
        ; a Breadbin disk?
        lda mo_dev
        ldx #<376
        ldy #>376
        jsr bread
        bcs @nodisk
        ldy #4
@m:     lda (bp),y
        cmp magic,y
        bne @cbm
        dey
        bpl @m
        ldx mo_dev
        lda #FS_C64
        sta dev_type,x
        lda mo_dev
        ldx #<376
        ldy #>376
        jsr mount_dev
        bcs @nodisk
        jmp @add
@cbm:   ; a CBM DOS disk: track 18 sector 0 is a BAM with format 'A'
        lda mo_dev
        ldx #<357
        ldy #>357
        jsr bread
        bcs @nodisk
        ldy #2
        lda (bp),y
        cmp #$41
        bne @nodisk
        ldx mo_dev
        lda #FS_CBM
        sta dev_type,x
@add:   ldx mo_dev
        lda #1
        sta dev_present,x
        ldx mo_ent
        lda #1
        sta mt_used,x
        lda mo_pdev
        sta mt_pdev,x
        lda mo_pino
        sta mt_pino,x
        lda mo_dev
        sta mt_dev,x
        jsr ent_path
        ldy #0
@cp:    lda pbuf,y
        sta (p1),y
        beq @fin
        iny
        cpy #31
        bne @cp
        lda #0
        sta (p1),y
@fin:   clc
        rts
@nodisk:
        ldx mo_dev
        jsr iec_close
        lda mo_dev
        jsr binval
        lda #ENODEV
        sec
        rts

; ---------------------------------------------------------------------
; diskio(A = drive 9-11, X = op): raw access to an unmounted drive, for
; /bin/format.  op 0: send the DOS command at r0 (NUL-terminated)
;               op 1: write the 256 bytes at r0 to block r1
;               op 2: read block r1 into the 256 bytes at r0
sys_diskio:
        stx mo_ent
        sec
        sbc #7
        cmp #2
        bcc @inval
        cmp #NDEV
        bcs @inval
        sta mo_dev
        tax
        lda dev_present,x
        beq @free
        lda #EBUSY
        sec
        rts
@inval: lda #EINVAL
        sec
        rts
@free:  ldx mo_dev
        jsr iec_open
        bcs @r
        lda mo_dev
        jsr binval
        lda mo_ent
        beq @cmd
        cmp #1
        beq @wr
        ; read
        lda mo_dev
        ldx r1
        ldy r1+1
        jsr bread
        bcs @done
        ldy #0
@rl:    lda (bp),y
        sta (r0),y
        iny
        bne @rl
        clc
        jmp @done
@wr:    lda mo_dev
        ldx r1
        ldy r1+1
        jsr bget_buf
        stx cb_cnt
        ldy #0
@wl:    lda (r0),y
        sta (bp),y
        iny
        bne @wl
        ldx cb_cnt
        jsr bwrite
        jmp @done
@cmd:   ldy #0
@cl:    lda (r0),y
        beq @ce
        sta cmdbuf,y
        iny
        cpy #39
        bne @cl
@ce:    sty cmdlen
        lda mo_dev
        jsr iec_command
@done:  php
        ldx mo_dev
        jsr iec_close
        lda mo_dev
        jsr binval
        plp
        bcc @r
        lda #EIO
@r:     rts
.import bwrite

; ent_path: X = mount entry -> p1 = &mt_path[x*32]
ent_path:
        txa
        asl a
        asl a
        asl a
        asl a
        asl a
        clc
        adc #<mt_path
        sta p1
        lda #>mt_path
        adc #0
        sta p1+1
        rts

; umount(r0 = mounted directory)
sys_umount:
        lda r0
        sta pp
        lda r0+1
        sta pp+1
        jsr namei
        bcs @r
        lda nm_ino
        cmp #ROOT_INO
        bne @inval
        lda nm_dev
        cmp #2
        bcc @inval
        sta mo_dev
        ; busy? open files or working directories on it
        ldx #NFILE-1
@f:     lda f_type,x
        cmp #FT_FILE
        beq @fd
        cmp #FT_DIR
        beq @fd
        cmp #FT_CBMW
        bne @fn
@fd:    lda f_dev,x
        cmp mo_dev
        beq @busy
@fn:    dex
        bpl @f
        ldx #MAXPROC-1
@p:     lda p_state,x
        beq @pn
        lda p_cwddev,x
        cmp mo_dev
        beq @busy
@pn:    dex
        bpl @p
        lda mo_dev
        jsr mnt_of_dev
        bcs @inval
        lda #0
        sta mt_used,x
        ldx mo_dev
        sta dev_present,x
        sta dev_type,x
        jsr iec_close
        lda mo_dev
        jsr binval
        clc
@r:     rts
@inval: lda #EINVAL
        sec
        rts
@busy:  lda #EBUSY
        sec
        rts
.import mnt_of_dev

; mntinfo(A = entry, r0 = buf[34]): drive (0 = REU), type, path[32]
sys_mntinfo:
        cmp #NMNT
        bcs @no
        tax
        lda mt_used,x
        beq @no
        lda mt_dev,x
        tay
        lda dev_drive,y
        ldy #0
        sta (r0),y
        lda mt_dev,x
        tay
        lda dev_type,y
        ldy #1
        sta (r0),y
        jsr ent_path
        lda r0
        clc
        adc #2
        sta p2
        lda r0+1
        adc #0
        sta p2+1
        ldy #0
@c:     lda (p1),y
        sta (p2),y
        iny
        cpy #32
        bne @c
        clc
        rts
@no:    lda #EINVAL
        sec
        rts

.segment "RODATA"
s_scr:  .byte "S0:", 0
s_ren:  .byte "R0:", 0
s_w0:   .byte "0:", 0
s_w1:   .byte ",S,W", 0
