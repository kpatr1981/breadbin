; Breadbin files: open-file table, descriptors, pipes, file syscalls
.include "k.inc"

FF_GONE = $80           ; f_flags: unlinked while open, freed at the last close

.importzp fb, pp
.import fs_name2, nm_dev, nm_ino, dl_off, f_done, dir_put, sb_ok
.import fs_count_inodes, sb_ninodes, mnt_ino, mnt_active, p_pslot
.import s_dot, s_dotdot, sb_nblocks_lo, sb_nblocks_hi, bm_alloc
.importzp bp

.segment "BSS"
f_type:  .res NFILE
f_ref:   .res NFILE
f_flags: .res NFILE
f_dev:   .res NFILE
f_ino:   .res NFILE
f_pos0:  .res NFILE
f_pos1:  .res NFILE
f_pos2:  .res NFILE
f_pipe:  .res NFILE
pi_used: .res NPIPE
pi_page: .res NPIPE
pi_r:    .res NPIPE
pi_w:    .res NPIPE
pi_n:    .res NPIPE
pi_rd:   .res NPIPE     ; open read ends
pi_wr:   .res NPIPE     ; open write ends
con_file: .res 1
of_flags: .res 1
of_fd:   .res 1
of_dev:  .res 1
of_ino:  .res 1
of_x:    .res 1
ou_t:    .res 1
rn_ino:  .res 1
rn_type: .res 1
rn_od:   .res 1
rn_opi:  .res 1
rn_npi:  .res 1
rn_ex:   .res 1
pbuf:    .res CWDLEN+16
pb_len:  .res 1
.export pbuf, build_path
.import cbm_read, cbm_readdir, cbm_open_write, cbm_write, cbm_wclose
.import cbm_scratch, cbm_rename, cbm_fsinfo

.segment "CODE"
file_init:
        ldx #NFILE-1
        lda #FT_FREE
@l:     sta f_type,x
        dex
        bpl @l
        ldx #NPIPE-1
        lda #0
@p:     sta pi_used,x
        dex
        bpl @p
        jsr oft_alloc
        stx con_file
        lda #FT_CON
        sta f_type,x
        lda #O_RDWR
        sta f_flags,x
        lda #0
        sta f_ref,x
        rts

; oft_alloc -> X = free entry (ref 1, pos 0), carry set if table full
oft_alloc:
        ldx #NFILE-1
@l:     lda f_type,x
        beq @f
        dex
        bpl @l
        lda #EMFILE
        sec
        rts
@f:     lda #1
        sta f_ref,x
        lda #0
        sta f_pos0,x
        sta f_pos1,x
        sta f_pos2,x
        sta f_flags,x
        lda #FT_NULL        ; placeholder so it counts as used
        sta f_type,x
        clc
        rts

; oft_ref: X = entry, ref++
oft_ref:
        inc f_ref,x
        rts

; oft_unref: A = entry. Drops a reference; frees the entry at zero.
; Uses only ou_t and A/X/Y, unless it closes the last open file of an
; unlinked inode: then it frees the inode (disk I/O; tmp3 and k_n kept).
oft_unref:
        tax
        dec f_ref,x
        bne @r
        lda f_type,x
        cmp #FT_PIPER
        beq @pr
        cmp #FT_CBMW
        bne @npw
        lda #FT_FREE
        sta f_type,x
        lda f_pipe,x
        jmp cbm_wclose
@npw:   cmp #FT_PIPEW
        bne @free
        ldy f_pipe,x
        lda pi_wr,y
        sec
        sbc #1
        sta pi_wr,y
        jmp @pclose
@pr:    ldy f_pipe,x
        lda pi_rd,y
        sec
        sbc #1
        sta pi_rd,y
@pclose:
        lda #FT_FREE
        sta f_type,x
        sty ou_t
        tya
        ora #CH_PIPE
        jsr wakeup
        ldy ou_t
        lda pi_rd,y
        ora pi_wr,y
        bne @r
        lda #0
        sta pi_used,y
        lda pi_page,y
        ldy #1
        jmp page_free
@free:  lda #FT_FREE
        sta f_type,x
        lda f_flags,x
        bmi ino_release
@r:     rts

; ino_release: X = the just-freed entry of a file unlinked while open.
; Frees the inode when no other open file uses it any more.
ino_release:
        lda tmp3
        pha
        lda f_ino,x
        pha
        lda f_dev,x
        tay
        pla
        tax
        tya
        ldy #0
        jsr ino_open
        bcs @done
        lda tmp0
        ldx tmp1
        jsr iget
        bcs @done
        lda ci+I_TYPE
        beq @done
        lda ci+I_NLINK
        bne @done
        jsr ifree
        jsr iput
@done:  pla
        sta tmp3
        rts

; ino_open: A = dev, X = ino, Y = f_flags bits to set on the open files of
; that inode -> carry set if there are any. Leaves tmp0/tmp1 = dev/ino.
ino_open:
        sta tmp0
        stx tmp1
        sty tmp2
        lda #0
        sta ou_t
        ldx #NFILE-1
@l:     lda f_type,x
        cmp #FT_FILE
        beq @c
        cmp #FT_DIR
        bne @n
@c:     lda f_dev,x
        cmp tmp0
        bne @n
        lda f_ino,x
        cmp tmp1
        bne @n
        lda f_flags,x
        ora tmp2
        sta f_flags,x
        sec
        ror ou_t
@n:     dex
        bpl @l
        asl ou_t
        rts

; ino_busy: A = dev, X = ino -> carry set if a file or a process's working
; directory uses it
ino_busy:
        ldy #0
        jsr ino_open
        bcs @r
        ldx #MAXPROC-1
@l:     lda p_state,x
        beq @n
        cmp #PS_ZOMBIE
        beq @n
        lda p_cwddev,x
        cmp tmp0
        bne @n
        lda p_cwdino,x
        cmp tmp1
        beq @y
@n:     dex
        bpl @l
        clc
@r:     rts
@y:     sec
        rts

; ifree: ci becomes a free inode (blocks released; caller iputs)
ifree:  jsr itrunc
        lda #0
        sta ci+I_TYPE
        rts

; fd_slot: A = fd -> X = index into p_fd (cur*8 + fd); carry set if fd bad
fd_slot:
        cmp #NFD
        bcs @bad
        sta tmp0
        lda cur
        asl a
        asl a
        asl a
        ora tmp0
        tax
        clc
        rts
@bad:   sec
        rts

; fd_get: A = fd -> X = open-file entry; carry set (A = EBADF) if bad
fd_get:
        jsr fd_slot
        bcs @bad
        lda p_fd,x
        cmp #$ff
        beq @bad
        tax
        clc
        rts
@bad:   lda #EBADF
        sec
        rts

; fd_alloc -> A = lowest free fd of cur, X = p_fd index
fd_alloc:
        lda #0
@l:     pha
        jsr fd_slot
        pla
        ldy p_fd,x
        cpy #$ff
        beq @f
        clc
        adc #1
        cmp #NFD
        bne @l
        lda #EMFILE
        sec
        rts
@f:     clc
        rts

; install: X = open-file entry -> A = new fd of cur (entry freed on error)
fd_install:
        stx of_x
        jsr fd_alloc
        bcs @e
        pha
        lda of_x
        sta p_fd,x
        pla
        clc
        rts
@e:     pha
        lda of_x
        jsr oft_unref
        pla
        sec
        rts

; ---------------------------------------------------------------------
; open(r0 = path, A = flags) -> A = fd
sys_open:
        sta of_flags
        lda r0
        sta pp
        lda r0+1
        sta pp+1
        jsr namei
        bcc @exists
        cmp #ENOENT
        bne @err
        lda of_flags
        and #O_CREAT
        bne @create
        lda #ENOENT
@err:   sec
        rts
@create:
        jsr nameiparent
        bcs @err
        ldx nm_dev
        lda dev_type,x
        beq @c64c
        jmp cbm_create
@c64c:  lda nm_dev
        sta of_dev
        lda nm_ino
        sta of_ino
        lda nm_dev
        ldx #T_FILE
        jsr ialloc
        bcs @err
        sta rn_ino
        lda of_dev
        ldx of_ino
        jsr iget
        bcs @undo
        lda rn_ino
        jsr dir_add
        bcs @undo
        lda rn_ino
        sta nm_ino
        lda of_dev
        sta nm_dev
        jmp @exists
@undo:  jmp undo_ialloc
@exists:
        lda nm_dev
        ldx nm_ino
        jsr iget
        bcs @err
        ldx nm_dev
        lda dev_type,x
        beq @c64o
        jmp cbm_open
@c64o:  jsr oft_alloc
        bcs @err
        lda nm_dev
        sta f_dev,x
        lda nm_ino
        sta f_ino,x
        lda of_flags
        sta f_flags,x
        lda ci+I_TYPE
        cmp #T_DIR
        beq @dir
        cmp #T_CHR
        beq @chr
        ; regular file
        lda #FT_FILE
        sta f_type,x
        lda of_flags
        and #O_TRUNC
        beq @inst
        lda of_flags
        and #(O_WRONLY | O_RDWR)
        beq @inst
        stx of_x
        jsr itrunc
        jsr iput
        ldx of_x
        jmp @inst
@dir:   lda of_flags
        and #(O_WRONLY | O_RDWR)
        beq @dok
        txa
        jsr oft_unref
        lda #EISDIR
        sec
        rts
@dok:   lda #FT_DIR
        sta f_type,x
        jmp @inst
@chr:   lda ci+I_MAJOR
        cmp #MAJ_CON
        beq @con
        lda #FT_NULL
        sta f_type,x
        jmp @inst
@con:   lda #FT_CON
        sta f_type,x
@inst:  jmp fd_install

; isatty(A = fd): carry clear if fd is the console
.export sys_isatty
sys_isatty:
        jsr fd_get
        bcs @r
        lda f_type,x
        cmp #FT_CON
        beq @y
        lda #EINVAL
        sec
@r:     rts
@y:     clc
        rts

; ---- open() on a CBM DOS disk ----
; cbm_open: existing entry (ci loaded, fs_name = its name)
cbm_open:
        lda of_flags
        and #O_APPEND
        beq @na
        lda #EINVAL
        sec
        rts
@na:    lda ci+I_TYPE
        cmp #T_DIR
        beq @dir
        lda of_flags
        and #(O_WRONLY | O_RDWR)
        bne cbm_create      ; writing replaces the file
        jsr oft_alloc
        bcs @r
        lda #FT_FILE
        sta f_type,x
        lda ci+I_DIRECT
        sta f_pos0,x        ; first track/sector, data from offset 2
        lda ci+I_DIRECT+1
        sta f_pos1,x
        lda #2
        sta f_pos2,x
        jmp @fin
@dir:   lda of_flags
        and #(O_WRONLY | O_RDWR)
        beq @rd
        lda #EISDIR
        sec
@r:     rts
@rd:    jsr oft_alloc
        bcs @r
        lda #FT_DIR
        sta f_type,x
        lda #18
        sta f_pos0,x
        lda #1
        sta f_pos1,x
        lda #0
        sta f_pos2,x
        sta f_pipe,x
@fin:   lda nm_dev
        sta f_dev,x
        lda nm_ino
        sta f_ino,x
        lda of_flags
        sta f_flags,x
        jmp fd_install

; cbm_create: new or replaced file, fs_name on device nm_dev
cbm_create:
        lda of_flags
        and #O_APPEND
        beq @na
        lda #EINVAL
        sec
        rts
@na:    lda nm_dev
        jsr cbm_open_write
        bcs @r
        pha
        jsr oft_alloc
        pla
        bcs @nofile
        sta f_pipe,x
        lda #FT_CBMW
        sta f_type,x
        lda nm_dev
        sta f_dev,x
        lda #O_WRONLY
        sta f_flags,x
        jmp fd_install
@nofile:
        jsr cbm_wclose
        lda #EMFILE
        sec
@r:     rts

; close(A = fd)
sys_close:
        jsr fd_slot
        bcs @bad
        lda p_fd,x
        cmp #$ff
        beq @bad
        pha
        lda #$ff
        sta p_fd,x
        pla
        jsr oft_unref
        clc
        rts
@bad:   lda #EBADF
        sec
        rts

; read(A = fd, r0 = buf, r1 = len) -> r1 = count
sys_read:
        jsr fd_get
        bcs @r
        stx sb6
        lda f_flags,x
        and #3
        cmp #O_WRONLY
        beq @bad
        lda f_type,x
        cmp #FT_FILE
        beq @file
        cmp #FT_DIR
        beq @file
        cmp #FT_CON
        bne @n1
        jmp con_read
@n1:    cmp #FT_PIPER
        bne *+5
        jmp pipe_read
        cmp #FT_NULL
        bne @bad
        lda #0
        sta r1
        sta r1+1
        clc
@r:     rts
@bad:   lda #EBADF
        sec
        rts
@file:  ldy f_dev,x
        lda dev_type,y
        beq @c64r
        lda f_type,x
        cmp #FT_DIR
        bne @cf
        jmp cbm_readdir
@cf:    jmp cbm_read
@c64r:  jsr file_setup
        bcs @r
        jsr fs_read
        bcs @r
        jmp file_done

; file_setup: X = entry -> ci loaded, f_off = pos, fb = r0, f_cnt = r1
file_setup:
        lda f_pos0,x
        sta f_off
        lda f_pos1,x
        sta f_off+1
        lda f_pos2,x
        sta f_off+2
        lda r0
        sta fb
        lda r0+1
        sta fb+1
        lda r1
        sta f_cnt
        lda r1+1
        sta f_cnt+1
        lda f_dev,x
        pha
        lda f_ino,x
        tax
        pla
        jmp iget

; file_done: store f_off back into entry sb6, r1 = f_done
file_done:
        ldx sb6
        lda f_off
        sta f_pos0,x
        lda f_off+1
        sta f_pos1,x
        lda f_off+2
        sta f_pos2,x
        lda f_done
        sta r1
        lda f_done+1
        sta r1+1
        clc
        rts

; pipe_read: entry in sb6
pipe_read:
        lda r1
        ora r1+1
        bne @again
        clc                 ; nothing asked for: r1 = 0 already
        rts
@again: ldx sb6
        ldy f_pipe,x
        sty sb5
        lda pi_n,y
        bne @data
        lda pi_wr,y
        bne @wait
        lda #0              ; no writers: EOF
        sta r1
        sta r1+1
        clc
        rts
@wait:  tya
        ora #CH_PIPE
        jsr block_on
        jmp @again
@data:  ; count = min(n, r1)
        sta sb4
        lda r1+1
        bne @n
        lda r1
        cmp sb4
        bcs @n
        sta sb4
@n:     ldy sb5
        lda #0
        sta p1
        lda pi_page,y
        sta p1+1
        lda #0
        sta tmp0
        ldx sb5
@cp:    ldy pi_r,x
        inc pi_r,x
        lda (p1),y
        ldy tmp0
        sta (r0),y
        inc tmp0
        lda tmp0
        cmp sb4
        bne @cp
        ldy sb5
        lda pi_n,y
        sec
        sbc sb4
        sta pi_n,y
        lda sb4
        sta r1
        lda #0
        sta r1+1
        tya
        ora #CH_PIPE
        jsr wakeup
        clc
        rts

; write(A = fd, r0 = buf, r1 = len) -> r1 = count
sys_write:
        jsr fd_get
        bcs @r
        stx sb6
        lda f_flags,x
        and #3
        cmp #O_RDONLY
        bne @wok
        lda f_type,x
        cmp #FT_CON
        beq @wok            ; console is always writable
        jmp @bad
@wok:   lda f_type,x
        cmp #FT_FILE
        beq @file
        cmp #FT_CON
        bne @n1
        jmp con_write
@n1:    cmp #FT_PIPEW
        beq pipe_write
        cmp #FT_CBMW
        bne @n2
        jmp cbm_write
@n2:    cmp #FT_NULL
        bne @bad
        clc
@r:     rts
@bad:   lda #EBADF
        sec
        rts
@file:  jsr file_setup
        bcs @r
        ldx sb6
        lda f_flags,x
        and #O_APPEND
        beq @w
        lda ci+I_SIZE
        sta f_off
        lda ci+I_SIZE+1
        sta f_off+1
        lda ci+I_SIZE+2
        sta f_off+2
@w:     jsr fs_write
        bcs @r
        jmp file_done

; pipe_write: entry in sb6; s0 = src, s1 = remaining, s2 = written
pipe_write:
        lda r0
        sta s0
        lda r0+1
        sta s0+1
        lda r1
        sta s1
        lda r1+1
        sta s1+1
        lda #0
        sta s2
        sta s2+1
@loop:  lda s1
        ora s1+1
        bne @more
        lda s2
        sta r1
        lda s2+1
        sta r1+1
        clc
        rts
@more:  ldx sb6
        ldy f_pipe,x
        sty sb5
        lda pi_rd,y
        bne @rd
        ldx cur             ; no readers: SIGPIPE
        lda #SIGPIPE
        sta p_sig,x
        lda #EPIPE
        sec
        rts
@rd:    lda #255
        sec
        sbc pi_n,y
        bne @space
        tya
        ora #CH_PIPE
        jsr block_on
        jmp @loop
@space: ; n = min(space, remaining)
        sta sb4
        lda s1+1
        bne @n
        lda s1
        cmp sb4
        bcs @n
        sta sb4
@n:     lda #0
        sta p1
        lda pi_page,y
        sta p1+1
        lda #0
        sta tmp0
        ldx sb5
@cp:    ldy tmp0
        lda (s0),y
        ldy pi_w,x
        inc pi_w,x
        sta (p1),y
        inc tmp0
        lda tmp0
        cmp sb4
        bne @cp
        ldy sb5
        lda pi_n,y
        clc
        adc sb4
        sta pi_n,y
        ; advance
        lda s0
        clc
        adc sb4
        sta s0
        bcc @a
        inc s0+1
@a:     lda s2
        clc
        adc sb4
        sta s2
        bcc @b
        inc s2+1
@b:     lda s1
        sec
        sbc sb4
        sta s1
        bcs @c
        dec s1+1
@c:     tya
        ora #CH_PIPE
        jsr wakeup
        jmp @loop

; pipe() -> A = read fd, X = write fd
sys_pipe:
        ldy #NPIPE-1
@f:     lda pi_used,y
        beq @got
        dey
        bpl @f
        lda #EMFILE
        sec
        rts
@got:   sty sb5
        ldy #1
        jsr page_alloc
        bcs @r
        ldy sb5
        sta pi_page,y
        lda #0
        sta pi_r,y
        sta pi_w,y
        sta pi_n,y
        lda #1
        sta pi_used,y
        sta pi_rd,y
        sta pi_wr,y
        ; read end
        jsr oft_alloc
        bcs @nofile
        lda #FT_PIPER
        sta f_type,x
        lda sb5
        sta f_pipe,x
        jsr fd_install
        bcs @nofd           ; (it dropped the read end: pi_rd = 0)
        sta sb3
        ; write end
        jsr oft_alloc
        bcs @nofile2
        lda #FT_PIPEW
        sta f_type,x
        lda #O_WRONLY
        sta f_flags,x
        lda sb5
        sta f_pipe,x
        jsr fd_install
        bcs @nofdw
        tax
        lda sb3
        clc
@r:     rts
@nofdw: pha                 ; closing the read end frees the pipe
        lda sb3
        jsr sys_close
        pla
        sec
        rts
@nofd:  pha
        ldy sb5
        lda #0
        sta pi_wr,y
        jmp @fr
@nofile2:
        pha
        lda sb3
        jsr sys_close
        ldy sb5
        lda #0
        sta pi_wr,y
        jmp @fr
@nofile:
        pha
@fr:    ldy sb5
        lda #0
        sta pi_used,y
        lda pi_page,y
        ldy #1
        jsr page_free
        pla
        sec
        rts

; ---------------------------------------------------------------------
; path helpers
set_pp_r0:
        lda r0
        sta pp
        lda r0+1
        sta pp+1
        rts

; is_dot: Z set if fs_name is "." or ".."
is_dot:
        lda fs_name
        cmp #'.'
        bne @r
        lda fs_name+1
        beq @r
        cmp #'.'
        bne @r
        lda fs_name+2
@r:     rts

save_name:
        ldx #15
@l:     lda fs_name,x
        sta fs_name2,x
        dex
        bpl @l
        rts

restore_name:
        ldx #15
@l:     lda fs_name2,x
        sta fs_name,x
        dex
        bpl @l
        rts

set_name_dot:
        ldx #15
@l:     lda s_dot,x
        sta fs_name,x
        dex
        bpl @l
        rts

set_name_dotdot:
        ldx #15
@l:     lda s_dotdot,x
        sta fs_name,x
        dex
        bpl @l
        rts

; not_cbm: carry set (A = EPERM) if nm_dev is a flat CBM disk
not_cbm:
        ldx nm_dev
        lda dev_type,x
        beq @ok
        lda #EPERM
        sec
        rts
@ok:    clc
        rts

; mkdir(r0 = path)
sys_mkdir:
        jsr set_pp_r0
        jsr nameiparent
        bcs @r
        jsr not_cbm
        bcs @r
        jsr dir_lookup
        beq @new
        lda #EEXIST
        sec
@r:     rts
@new:   jsr save_name
        lda nm_dev
        sta of_dev
        lda nm_ino
        sta of_ino
        lda nm_dev
        ldx #T_DIR
        jsr ialloc
        bcs @r
        sta rn_ino
        lda #2
        sta ci+I_NLINK
        jsr set_name_dot
        lda rn_ino
        jsr dir_add
        bcs @undo
        jsr set_name_dotdot
        lda of_ino
        jsr dir_add
        bcs @undo
        lda of_dev
        ldx of_ino
        jsr iget
        bcs @undo
        jsr restore_name
        lda rn_ino
        jsr dir_add
        bcs @undo
        inc ci+I_NLINK
        jmp iput
@undo:  jmp undo_ialloc

; undo_ialloc: A = errno. Free inode rn_ino on of_dev, allocated but never
; linked into its directory (the disk filled up). Returns carry set, A.
undo_ialloc:
        pha
        lda of_dev
        ldx rn_ino
        jsr iget
        bcs @r
        jsr ifree
        jsr iput
@r:     pla
        sec
        rts

; rmdir(r0 = path)
sys_rmdir:
        jsr set_pp_r0
        jsr nameiparent
        bcs @r
        jsr not_cbm
        bcs @r
        jsr is_dot
        bne @nd
        lda #EINVAL
        sec
@r:     rts
@nd:    lda nm_dev
        sta of_dev
        lda nm_ino
        sta of_ino
        jsr dir_lookup
        bne @f
        lda #ENOENT
        sec
        rts
@f:     sta rn_ino
        lda of_dev
        ldx rn_ino
        .import mnt_point
        jsr mnt_point
        bcc @busy
        lda of_dev
        ldx rn_ino
        jsr ino_busy
        bcc @nm
@busy:  lda #EBUSY
        sec
        rts
@nm:    lda of_dev
        ldx rn_ino
        jsr iget
        bcs @r
        lda ci+I_TYPE
        cmp #T_DIR
        beq @isd
        lda #ENOTDIR
        sec
        rts
@isd:   jsr dir_empty
        beq @emp
        lda #ENOTEMPTY
        sec
        rts
@emp:   jsr itrunc
        lda #0
        sta ci+I_TYPE
        sta ci+I_NLINK
        jsr iput
        bcs @r
        lda of_dev
        ldx of_ino
        jsr iget
        bcs @r
        jsr dir_remove
        bcs @r
        dec ci+I_NLINK
        jmp iput

; unlink(r0 = path)
sys_unlink:
        jsr set_pp_r0
        jsr nameiparent
        bcs @r
        lda nm_dev
        sta of_dev
        lda nm_ino
        sta of_ino
        jsr dir_lookup
        bne @f
        lda #ENOENT
        sec
@r:     rts
@f:     sta rn_ino
        ldx of_dev
        lda dev_type,x
        beq @c64u
        lda of_dev
        jmp cbm_scratch
@c64u:  lda of_dev
        ldx rn_ino
        jsr iget
        bcs @r
        lda ci+I_TYPE
        cmp #T_DIR
        bne @nd
        lda #EISDIR
        sec
        rts
@nd:    lda of_dev
        ldx of_ino
        jsr iget
        bcs @r
        jsr dir_remove
        bcs @r
        lda of_dev
        ldx rn_ino
; drop a link from inode X on dev A; free it when none are left, or, while
; it is still open, at its last close
drop_link:
        jsr iget
        bcs @r
        dec ci+I_NLINK
        bne @put
        lda ci_dev
        ldx ci_ino
        ldy #FF_GONE
        jsr ino_open
        bcs @put
        jsr ifree
@put:   jmp iput
@r:     rts

; rename(r0 = old, r1 = new)
sys_rename:
        jsr set_pp_r0
        jsr nameiparent
        bcs @r
        jsr is_dot
        bne @nd
@inval: lda #EINVAL
        sec
@r:     rts
@nd:    lda nm_dev
        sta rn_od
        lda nm_ino
        sta rn_opi
        jsr dir_lookup
        bne @f
        lda #ENOENT
        sec
        rts
@f:     sta rn_ino
        jsr save_name
        lda rn_od
        ldx rn_ino
        jsr iget
        bcs @r
        lda ci+I_TYPE
        sta rn_type
        lda r1
        sta pp
        lda r1+1
        sta pp+1
        jsr nameiparent
        bcs @r
        jsr is_dot
        beq @inval
        lda nm_dev
        cmp rn_od
        beq @samedev
        lda #EXDEV
        sec
        rts
@samedev:
        ldx rn_od
        lda dev_type,x
        beq @c64n
        lda rn_od
        jmp cbm_rename      ; fs_name2 = old, fs_name = new
@c64n:  lda nm_ino
        sta rn_npi
        lda rn_type
        cmp #T_DIR
        bne @nsub
        jsr in_subtree
        bcc @nsub2
        jmp @inval
@nsub2: lda rn_od           ; in_subtree changed ci: the new parent again
        ldx rn_npi
        jsr iget
        bcc @nsub
        rts
@nsub:  jsr dir_lookup
        beq @add
        sta rn_ex
        cmp rn_ino
        bne @ex
        clc                 ; renaming onto itself
        rts
@ex:    ; replace an existing file
        lda rn_od
        ldx rn_ex
        jsr iget
        bcs @r2
        lda ci+I_TYPE
        cmp #T_DIR
        bne @rep
        lda #EEXIST
        sec
@r2:    rts
@rep:   lda rn_od
        ldx rn_npi
        jsr iget
        bcs @r2
        jsr dir_lookup      ; recompute dl_off for the target name
        lda rn_ino
        jsr dir_put
        bcs @r2
        lda rn_od
        ldx rn_ex
        jsr drop_link
        jmp @rmold
@add:   lda rn_ino
        jsr dir_add
        bcs @r2
@rmold: lda rn_od
        ldx rn_opi
        jsr iget
        bcs @r2
        jsr restore_name
        jsr dir_remove
        bcs @r2
        ; a moved directory gets a new ".."
        lda rn_type
        cmp #T_DIR
        bne @done
        lda rn_opi
        cmp rn_npi
        beq @done
        lda rn_od
        ldx rn_ino
        jsr iget
        bcs @r2
        jsr set_name_dotdot
        jsr dir_lookup
        lda rn_npi
        jsr dir_put
        lda rn_od
        ldx rn_opi
        jsr iget
        dec ci+I_NLINK
        jsr iput
        lda rn_od
        ldx rn_npi
        jsr iget
        inc ci+I_NLINK
        jmp iput
@done:  clc
        rts

; in_subtree: carry set if directory rn_npi (on rn_od) is rn_ino or lies
; below it. Walks up through each directory's ".." (its second entry).
in_subtree:
        lda rn_npi
@l:     cmp rn_ino
        beq @y
        cmp #ROOT_INO
        beq @n
        tax
        lda rn_od
        jsr iget
        bcs @n
        lda #0
        sta bm_alloc
        jsr bmap
        bcs @n
        lda ci_dev
        jsr bread
        bcs @n
        ldy #DIRENT
        lda (bp),y
        jmp @l
@y:     sec
        rts
@n:     clc
        rts

; ---------------------------------------------------------------------
; chdir(r0 = path)
sys_chdir:
        jsr set_pp_r0
        jsr namei
        bcs @r
        lda nm_dev
        ldx nm_ino
        jsr iget
        bcs @r
        lda ci+I_TYPE
        cmp #T_DIR
        beq @d
        lda #ENOTDIR
        sec
@r:     rts
@d:     jsr build_path
        bcs @r
        ldx cur
        lda nm_dev
        sta p_cwddev,x
        lda nm_ino
        sta p_cwdino,x
        ; copy pbuf into p_cwd[cur]
        jsr cwd_ptr
        ldy #0
@c:     lda pbuf,y
        sta (p1),y
        beq @e
        iny
        bne @c
@e:     clc
        rts

; cwd_ptr: p1 = &p_cwd[cur*48]
cwd_ptr:
        lda cur
        asl a
        asl a
        asl a
        asl a               ; *16
        sta p1
        lda #0
        sta p1+1
        lda p1
        asl a
        sta tmp0
        lda #0
        rol a
        sta tmp1            ; *32
        lda p1
        clc
        adc tmp0
        sta p1
        lda tmp1
        adc #0
        sta p1+1            ; *48
        lda p1
        clc
        adc #<p_cwd
        sta p1
        lda p1+1
        adc #>p_cwd
        sta p1+1
        rts
.export cwd_ptr

; build_path: normalize (pp) relative to cwd into pbuf
build_path:
        ldy #0
        lda (pp),y
        cmp #'/'
        beq @abs
        jsr cwd_ptr
        ldy #0
@cc:    lda (p1),y
        sta pbuf,y
        beq @ce
        iny
        bne @cc
@ce:    sty pb_len
        cpy #1
        bne @src
        dec pb_len          ; "/" -> empty, components add "/x"
        jmp @src
@abs:   lda #0
        sta pb_len
@src:   ldy #0
@loop:  lda (pp),y
        beq @fin
        cmp #'/'
        bne @comp
        iny
        bne @loop
@comp:  ; component at y: check "." and ".."
        cmp #'.'
        bne @app
        iny
        lda (pp),y
        dey
        cmp #'/'
        beq @dot
        cmp #0
        beq @dot
        cmp #'.'
        bne @app
        iny
        iny
        lda (pp),y
        dey
        dey
        cmp #'/'
        beq @dd
        cmp #0
        bne @app
@dd:    ; remove last component
        ldx pb_len
@rm:    dex
        bmi @rmz
        lda pbuf,x
        cmp #'/'
        bne @rm
        stx pb_len
        jmp @skipc
@rmz:   lda #0
        sta pb_len
@skipc: iny
        iny
        jmp @loop
@dot:   iny
        jmp @loop
@app:   ldx pb_len
        lda #'/'
        sta pbuf,x
        inx
@ac:    lda (pp),y
        beq @ad
        cmp #'/'
        beq @ad
        sta pbuf,x
        inx
        cpx #CWDLEN-1
        bcs @long
        iny
        bne @ac
@ad:    stx pb_len
        jmp @loop
@long:  lda #ENAMETOOLONG
        sec
        rts
@fin:   ldx pb_len
        bne @nz
        lda #'/'
        sta pbuf
        inx
@nz:    lda #0
        sta pbuf,x
        clc
        rts

; getcwd(r0 = buf, A = size)
sys_getcwd:
        sta tmp2
        jsr cwd_ptr
        ldy #0
@l:     cpy tmp2
        bcs @big
        lda (p1),y
        sta (r0),y
        beq @d
        iny
        bne @l
@big:   lda #EINVAL
        sec
        rts
@d:     clc
        rts

; stat(r0 = path, r1 = buf[8]): type nlink size(3) ino dev major
sys_stat:
        jsr set_pp_r0
        jsr namei
        bcs @r
        lda nm_dev
        ldx nm_ino
        jsr iget
        bcs @r
        ldy #0
        lda ci+I_TYPE
        sta (r1),y
        iny
        lda ci+I_NLINK
        sta (r1),y
        iny
        lda ci+I_SIZE
        sta (r1),y
        iny
        lda ci+I_SIZE+1
        sta (r1),y
        iny
        lda ci+I_SIZE+2
        sta (r1),y
        iny
        lda nm_ino
        sta (r1),y
        iny
        lda nm_dev
        sta (r1),y
        iny
        lda ci+I_MAJOR
        sta (r1),y
        clc
@r:     rts

; fsinfo(r0 = path, r1 = buf[8]): free blocks(2) total blocks(2)
;                                  free inodes, total inodes, dev
sys_fsinfo:
        jsr set_pp_r0
        jsr namei
        bcs @r
        ldx nm_dev
        lda dev_type,x
        beq @c64
        lda nm_dev
        jsr cbm_fsinfo
        bcs @r
        tya
        ldy #1
        sta (r1),y
        txa
        dey
        sta (r1),y
        ldy #2
        lda #<664
        sta (r1),y
        iny
        lda #>664
        sta (r1),y
        iny
        lda #0
        sta (r1),y
        iny
        sta (r1),y
        iny
        lda nm_dev
        sta (r1),y
        clc
        rts
@c64:   lda nm_dev
        jsr fs_count_free
        bcs @r
        tya
        pha
        txa
        ldy #0
        sta (r1),y
        iny
        pla
        sta (r1),y
        iny
        ldx nm_dev
        lda sb_nblocks_lo,x
        sta (r1),y
        iny
        lda sb_nblocks_hi,x
        sta (r1),y
        lda nm_dev
        jsr fs_count_inodes
        bcs @r
        ldy #4
        txa
        sta (r1),y
        iny
        ldx nm_dev
        lda sb_ninodes,x
        sec
        sbc #1
        sta (r1),y
        iny
        lda nm_dev
        sta (r1),y
        clc
@r:     rts
