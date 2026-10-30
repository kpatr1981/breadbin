; Breadbin program loader: spawn()
;
; Loads a CX executable into freshly allocated pages, applies its
; relocations, copies argv into the child's memory and makes it ready.
.include "k.inc"

.importzp fb, pp
.import f_done, p_pslot, new_slot, proc_entry, name_off, con_file, find_pid
.import cwd_ptr, nm_dev, nm_ino, p_uid

MAXARGS = 16

.segment "BSS"
sp_in:    .res 1        ; open-file entries for child fd 0/1/2
sp_out:   .res 1
sp_err:   .res 1
sp_flags: .res 1
sp_slot:  .res 1
hdr:      .res 9
img_sz:   .res 2
bss_sz:   .res 2
nrel:     .res 2
argsz:    .res 2
nargs:    .res 1
base:     .res 1        ; first page
npages:   .res 1
rbuf:     .res 128
rcnt:     .res 1
kargv:    .res 4        ; argv for kernel spawn: {path, NULL}
dst:      .res 2

.segment "CODE"
; spawn_kernel: A/X = path (kernel memory). Starts init with console fds.
spawn_kernel:
        sta r0
        stx r0+1
        sta kargv
        stx kargv+1
        lda #0
        sta kargv+2
        sta kargv+3
        lda #<kargv
        sta r1
        lda #>kargv
        sta r1+1
        ldx con_file
        stx sp_in
        stx sp_out
        stx sp_err
        lda #SP_IGNINT
        sta sp_flags
        jmp spawn_common

; spawn(r0 = path, r1 = argv, A = stdin fd, X = stdout fd, Y = flags)
sys_spawn:
        sty sp_flags
        stx sp_out
        jsr fd_get
        bcs @r
        stx sp_in
        lda sp_out
        jsr fd_get
        bcs @r
        stx sp_out
        lda #2
        jsr fd_get
        bcc @e
        ldx #$ff
@e:     stx sp_err
        lda r1
        ora r1+1
        bne spawn_common
        ; no argv given: use {path}
        lda r0
        sta kargv
        lda r0+1
        sta kargv+1
        lda #0
        sta kargv+2
        sta kargv+3
        lda #<kargv
        sta r1
        lda #>kargv
        sta r1+1
        jmp spawn_common
@r:     rts

spawn_common:
        ; free slot
        ldx #MAXPROC-1
@fs:    lda p_state,x
        beq @slot
        dex
        bpl @fs
        lda #EAGAIN
        sec
        rts
@slot:  stx sp_slot
        ; find and check the program
        lda r0
        sta pp
        lda r0+1
        sta pp+1
        jsr namei
        bcs @r
        ldx nm_dev
        lda dev_type,x      ; programs only run from c64fs
        beq @c64
        lda #ENOEXEC
        sec
        rts
@c64:   lda nm_dev
        ldx nm_ino
        jsr iget
        bcs @r
        lda ci+I_TYPE
        cmp #T_FILE
        beq @isf
        lda #ENOEXEC
        sec
@r:     rts
@isf:   lda #0
        sta f_off
        sta f_off+1
        sta f_off+2
        lda #<hdr
        sta fb
        lda #>hdr
        sta fb+1
        lda #9
        sta f_cnt
        lda #0
        sta f_cnt+1
        jsr fs_read
        bcs @r
        lda f_done
        cmp #9
        bne @noexec
        lda hdr
        cmp #'C'
        bne @noexec
        lda hdr+1
        cmp #'X'
        bne @noexec
        lda hdr+2
        cmp #1
        beq @hok
@noexec:
        lda #ENOEXEC
        sec
        rts
@hok:   ldx #5
@hc:    lda hdr+3,x
        sta img_sz,x
        dex
        bpl @hc
        jsr measure_args
        bcs @r
        ; npages = ceil((img + bss + args) / 256)
        lda img_sz
        clc
        adc bss_sz
        sta dst
        lda img_sz+1
        adc bss_sz+1
        sta dst+1
        bcs @nomem
        lda dst
        clc
        adc argsz
        sta dst
        lda dst+1
        adc argsz+1
        bcs @nomem
        ldx dst
        beq @np
        clc
        adc #1
        bcs @nomem
@np:    sta npages
        tay
        jsr page_alloc
        bcc @mem
@nomem: lda #ENOMEM
        sec
        rts
@mem:   sta base
        ; load the image
        lda #9
        sta f_off
        lda #0
        sta f_off+1
        sta f_off+2
        sta fb
        lda base
        sta fb+1
        lda img_sz
        sta f_cnt
        lda img_sz+1
        sta f_cnt+1
        jsr fs_read
        bcs @fail
        lda f_done
        cmp img_sz
        bne @bad
        lda f_done+1
        cmp img_sz+1
        bne @bad
        jsr relocate
        bcs @fail
        jsr zero_bss
        jsr copy_args
        jsr setup_proc
        clc
        rts
@bad:   lda #ENOEXEC
@fail:  pha
        lda base
        ldy npages
        jsr page_free
        pla
        sec
        rts

; relocate: read nrel offsets after the image; base[off] += base page
relocate:
@chunk: lda nrel
        ora nrel+1
        bne @more
        clc
        rts
@more:  ; up to 64 relocations (128 bytes) per chunk
        lda #64
        ldx nrel+1
        bne @c
        cmp nrel
        bcc @c
        lda nrel
@c:     sta rcnt
        asl a
        sta f_cnt
        lda #0
        sta f_cnt+1
        lda #<rbuf
        sta fb
        lda #>rbuf
        sta fb+1
        jsr fs_read         ; f_off continues after the image
        bcs @r
        lda f_done
        lsr a
        cmp rcnt
        bne @bad
        ldx #0
@l:     lda rbuf,x
        sta p1
        lda rbuf+1,x
        clc
        adc base
        sta p1+1
        ldy #0
        lda (p1),y
        clc
        adc base
        sta (p1),y
        inx
        inx
        dec rcnt
        bne @l
        lda f_done
        lsr a
        sta tmp0
        lda nrel
        sec
        sbc tmp0
        sta nrel
        bcs @chunk
        dec nrel+1
        jmp @chunk
@bad:   lda #ENOEXEC
        sec
@r:     rts

zero_bss:
        lda #0
        sta p1
        lda base
        clc
        adc img_sz+1
        sta p1+1
        ldy img_sz          ; p1 = base + img (as page + y)
        lda bss_sz
        sta tmp0
        lda bss_sz+1
        sta tmp1
@l:     lda tmp0
        ora tmp1
        beq @d
        lda #0
        sta (p1),y
        iny
        bne @n
        inc p1+1
@n:     lda tmp0
        bne @dl
        dec tmp1
@dl:    dec tmp0
        jmp @l
@d:     rts

; measure_args: count argv (r1) -> nargs, argsz = 2*(n+1) + sum(len+1)
measure_args:
        lda r1
        sta p1
        lda r1+1
        sta p1+1
        lda #0
        sta nargs
        sta argsz
        sta argsz+1
@l:     ldy #0
        lda (p1),y
        sta p2
        iny
        lda (p1),y
        sta p2+1
        ora p2
        beq @end
        ldy #0
@s:     lda (p2),y
        beq @se
        iny
        bne @s
        lda #E2BIG
        sec
        rts
@se:    iny                 ; include NUL
        tya
        clc
        adc argsz
        sta argsz
        bcc @nc
        inc argsz+1
@nc:    inc nargs
        lda nargs
        cmp #MAXARGS
        bcc @nx
        lda #E2BIG
        sec
        rts
@nx:    lda p1
        clc
        adc #2
        sta p1
        bcc @l
        inc p1+1
        jmp @l
@end:   lda nargs
        asl a
        clc
        adc #2
        adc argsz
        sta argsz
        bcc @r
        inc argsz+1
@r:     clc
        rts

; copy_args: build argv at base + img + bss: pointer array, then strings
copy_args:
        ; p3 = array start
        lda img_sz
        clc
        adc bss_sz
        sta p3
        lda img_sz+1
        adc bss_sz+1
        clc
        adc base
        sta p3+1
        ; dst = string area = p3 + 2*(n+1)
        lda nargs
        asl a
        clc
        adc #2
        clc
        adc p3
        sta dst
        lda p3+1
        adc #0
        sta dst+1
        lda r1
        sta p1
        lda r1+1
        sta p1+1
        ldx nargs
@a:     cpx #0
        beq @fin
        ldy #0
        lda (p1),y
        sta p2
        iny
        lda (p1),y
        sta p2+1
        ; store pointer
        dey
        lda dst
        sta (p3),y
        iny
        lda dst+1
        sta (p3),y
        ; copy string
        lda dst
        sta p4
        lda dst+1
        sta p4+1
        ldy #0
@cs:    lda (p2),y
        sta (p4),y
        beq @ce
        iny
        bne @cs
@ce:    iny
        tya
        clc
        adc dst
        sta dst
        bcc @nc
        inc dst+1
@nc:    lda p3
        clc
        adc #2
        sta p3
        bcc @n3
        inc p3+1
@n3:    lda p1
        clc
        adc #2
        sta p1
        bcc @n1
        inc p1+1
@n1:    dex
        jmp @a
@fin:   ldy #0
        tya
        sta (p3),y
        iny
        sta (p3),y
        rts

; setup_proc: fill in the process table entry and its initial context
setup_proc:
@np:    lda next_pid        ; the next pid no live or zombie process holds
        inc next_pid
        bne @p
        ldx #2
        stx next_pid
@p:     jsr find_pid
        bcc @np
        ldx sp_slot
        sta p_pid,x
        lda #0
        sta p_sig,x
        sta p_exit,x
        lda sp_flags
        sta p_flags,x
        lda base
        sta p_mpage,x
        lda npages
        sta p_mlen,x
        lda cur
        sta p_pslot,x
        cmp #$ff
        bne @par
        lda #0
        sta p_ppid,x
        sta p_cwddev,x
        lda #ROOT_INO
        sta p_cwdino,x
        lda #0
        sta p_uid,x
        jmp @fd
@par:   tay
        lda p_pid,y
        sta p_ppid,x
        lda p_uid,y
        sta p_uid,x
        lda p_cwddev,y
        sta p_cwddev,x
        lda p_cwdino,y
        sta p_cwdino,x
@fd:    ; descriptors
        txa
        asl a
        asl a
        asl a
        tay
        lda #$ff
        ldx #NFD
@fc:    sta p_fd,y
        iny
        dex
        bne @fc
        tya
        sec
        sbc #NFD
        tay
        ldx sp_in
        jsr give_fd
        ldx sp_out
        jsr give_fd
        ldx sp_err
        jsr give_fd
        ; name = basename(path), max 10 chars
        jsr set_name
        ; cwd
        jsr copy_cwd
        ; saved context: zero ZP image, then argv/argc/entry
        ldx sp_slot
        jsr slot_save_ptr
        ldy #0
        tya
@z:     sta (p3),y
        iny
        cpy #ZPSAVE
        bne @z
        lda img_sz
        clc
        adc bss_sz
        ldy #argv-2
        sta (p3),y
        lda img_sz+1
        adc bss_sz+1
        clc
        adc base
        iny
        sta (p3),y
        lda nargs
        ldy #argc-2
        sta (p3),y
        lda #0
        ldy #k_entry-2
        sta (p3),y
        lda base
        iny
        sta (p3),y
        ; initial stack: P, then return address into proc_entry
        ldy #ZPSAVE
        lda #$04
        sta (p3),y
        iny
        lda #<(proc_entry-1)
        sta (p3),y
        iny
        lda #>(proc_entry-1)
        sta (p3),y
        ldx sp_slot
        lda #$fc
        sta p_sp,x
        lda #PS_READY
        sta p_state,x
        lda p_pid,x
        clc
        rts

; give_fd: X = open-file entry ($ff = none), Y = p_fd index; Y++
give_fd:
        txa
        sta p_fd,y
        cmp #$ff
        beq @n
        inc f_ref,x
@n:     iny
        rts

set_name:
        lda sp_slot
        jsr name_off
        sta tmp2
        ; find last '/'
        ldy #0
        sty tmp0
@f:     lda (pp),y
        beq @fe
        iny
        cmp #'/'
        bne @f
        sty tmp0
        jmp @f
@fe:    ldy tmp0
        ldx tmp2
        lda #NAMELEN-1
        sta tmp1
@c:     lda (pp),y
        beq @ce
        sta p_name,x
        inx
        iny
        dec tmp1
        bne @c
@ce:    lda #0
        sta p_name,x
        rts

copy_cwd:
        lda cur
        cmp #$ff
        bne @par
        ; root: "/"
        lda sp_slot
        sta cur
        jsr cwd_ptr
        lda #$ff
        sta cur
        ldy #0
        lda #'/'
        sta (p1),y
        iny
        lda #0
        sta (p1),y
        rts
@par:   jsr cwd_ptr
        lda p1
        sta p2
        lda p1+1
        sta p2+1
        lda cur
        pha
        lda sp_slot
        sta cur
        jsr cwd_ptr
        pla
        sta cur
        ldy #CWDLEN-1
@l:     lda (p2),y
        sta (p1),y
        dey
        bpl @l
        rts
