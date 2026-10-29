; c64os processes: table, scheduler, context switch, IRQ, signals
;
; Context switch model: the kernel is not preemptible (in_kernel != 0);
; user code is. Every saved context lives inside a call to `sched`: it
; pushes P, saves SP, ZP $02-$3F and the used part of the stack page into
; the process's save area, then restores another process the same way and
; returns (plp/rts) into *that* process's call to sched.
.include "k.inc"

.segment "BSS"
p_state:  .res MAXPROC
p_pid:    .res MAXPROC
p_ppid:   .res MAXPROC
p_pslot:  .res MAXPROC      ; parent slot ($FF for init)
p_flags:  .res MAXPROC
p_chan:   .res MAXPROC
p_sp:     .res MAXPROC
p_mpage:  .res MAXPROC
p_mlen:   .res MAXPROC
p_sig:    .res MAXPROC
p_exit:   .res MAXPROC
p_cwdino: .res MAXPROC
p_cwddev: .res MAXPROC
p_name:   .res MAXPROC*NAMELEN
p_fd:     .res MAXPROC*NFD
p_cwd:    .res MAXPROC*CWDLEN
p_save:   .res MAXPROC*SAVESZ
next_pid: .res 1
new_slot: .res 1
wk_ch:    .res 1

.export p_pslot, new_slot, proc_entry

.segment "RODATA"
s_stk:  .byte "stack overflow", 0
s_init: .byte "init exited", 0

.segment "CODE"
proc_init:
        ldx #MAXPROC-1
        lda #PS_FREE
@l:     sta p_state,x
        dex
        bpl @l
        lda #1
        sta next_pid
        rts

; slot_save_ptr: X = slot -> p3 = &p_save[slot*192]. Preserves X.
slot_save_ptr:
        txa
        lsr a
        lsr a               ; hi byte of slot*64
        sta p3+1
        txa
        asl a
        asl a
        asl a
        asl a
        asl a
        asl a               ; lo byte of slot*64
        sta p3
        ; p3 = slot*64; want slot*192 = slot*64*3
        lda p3
        asl a
        sta tmp0
        lda p3+1
        rol a
        sta tmp1            ; tmp = slot*128
        lda p3
        clc
        adc tmp0
        sta p3
        lda p3+1
        adc tmp1
        sta p3+1
        lda p3
        clc
        adc #<p_save
        sta p3
        lda p3+1
        adc #>p_save
        sta p3+1
        rts

; sched: switch to the next ready process. Called with in_kernel set.
sched:
        php
        sei
        ldx cur
        cpx #$ff
        beq @pick
        lda p_state,x
        beq @pick           ; free
        cmp #PS_ZOMBIE
        beq @pick
        ; save current context
        tsx
        stx tmp2
        cpx #$ff - STKSAVE
        bcs @stkok
        lda #<s_stk
        ldx #>s_stk
        jmp panic
@stkok: ldx cur
        lda tmp2
        sta p_sp,x
        jsr slot_save_ptr
        ldy #0
@zs:    lda $02,y
        sta (p3),y
        iny
        cpy #ZPSAVE
        bne @zs
        ldx tmp2
@ss:    inx
        lda $0100,x
        sta (p3),y
        iny
        cpx #$ff
        bne @ss

@pick:  ldx cur
        cpx #$ff
        bne @rr
        ldx #MAXPROC-1
@rr:    ldy #MAXPROC
@n:     inx
        cpx #MAXPROC
        bcc @c
        ldx #0
@c:     lda p_state,x
        cmp #PS_READY
        beq @found
        dey
        bne @n
        ; nothing ready: idle with interrupts on until something wakes
        lda #$ff
        sta cur
@idle:  cli
        nop
        sei
        ldx #MAXPROC-1
@il:    lda p_state,x
        cmp #PS_READY
        beq @found
        dex
        bpl @il
        jmp @idle

@found: stx cur
        lda #SLICE
        sta slice
        jsr slot_save_ptr
        ldy #0
@zr:    lda (p3),y
        sta $0002,y
        iny
        cpy #ZPSAVE
        bne @zr
        lda p_sp,x
        tax
        txs
@sr:    inx
        lda (p3),y
        sta $0100,x
        iny
        cpx #$ff
        bne @sr
        plp
        rts

; first code a new process runs (via its crafted saved stack)
proc_entry:
        lda #0
        sta in_kernel
        lda #>(user_ret-1)
        pha
        lda #<(user_ret-1)
        pha
        cli
        jmp (k_entry)
user_ret:
        lda #0
        jmp SYS_EXIT

; block_on: A = channel. Sleep until wakeup(channel); then act on signals.
block_on:
        pha
        jsr check_signal
        pla
        ldx cur
        sta p_chan,x
        lda #PS_BLOCKED
        sta p_state,x
        jsr sched
        ; fall through
; check_signal: if the current process has a pending signal, it exits.
check_signal:
        ldx cur
        lda p_sig,x
        beq @r
        ora #$80
        jmp proc_exit
@r:     rts

; wakeup: A = channel. Make every process blocked on it ready.
wakeup:
        sta wk_ch
        ldx #MAXPROC-1
@l:     lda p_state,x
        cmp #PS_BLOCKED
        bne @n
        lda p_chan,x
        cmp wk_ch
        bne @n
        lda #PS_READY
        sta p_state,x
@n:     dex
        bpl @l
        rts

; ---------------------------------------------------------------------
irq:
        cld
        lda $dc0d           ; acknowledge CIA1 timer
        jsr UDTIM
        jsr SCNKEY
        inc ticks
        bne @t
        inc ticks+1
        bne @t
        inc ticks+2
@t:     jsr con_cursor_tick
        lda #CH_TICK
        jsr wakeup
        ; RUN/STOP edge -> SIGINT to foreground processes
        lda $91
        cmp #$7f
        bne @nostop
        cmp stop_prev
        beq @stopd
        sta stop_prev
        jsr sigint_fg
        jmp @stopd
@nostop: sta stop_prev
@stopd: lda in_kernel
        bne @kern
        ldx cur
        cpx #$ff
        beq @out
        lda p_sig,x
        bne @die
        dec slice
        bne @out
        lda #1
        sta in_kernel
        jsr sched
        ldx cur
        lda p_sig,x
        bne @die
        lda #0
        sta in_kernel
@out:   jmp $ea81           ; pla/tay/pla/tax/pla/rti
@kern:  dec slice
        bne @out
        lda #1
        sta need_resched
        jmp $ea81
@die:   lda #1
        sta in_kernel
        lda p_sig,x
        ora #$80
        jmp proc_exit

sigint_fg:
        ldx #MAXPROC-1
@l:     lda p_state,x
        cmp #PS_READY
        beq @y
        cmp #PS_BLOCKED
        bne @n
@y:     lda p_flags,x
        and #(SP_BG | SP_IGNINT)
        bne @n
        lda #SIGINT
        sta p_sig,x
        lda #PS_READY
        sta p_state,x
@n:     dex
        bpl @l
        rts

; ---------------------------------------------------------------------
; proc_exit: A = exit code. Tear down the current process. Never returns.
proc_exit:
        ldx cur
        sta p_exit,x
        lda p_pid,x
        cmp #1
        bne @notinit
        lda #<s_init
        ldx #>s_init
        jmp panic
@notinit:
        ; close fds
        txa
        asl a
        asl a
        asl a
        sta tmp3            ; fd base index
        ldy #0
@fd:    sty k_n
        ldx tmp3
        lda p_fd,x
        cmp #$ff
        beq @fdn
        pha
        lda #$ff
        sta p_fd,x
        pla
        jsr oft_unref
@fdn:   inc tmp3
        ldy k_n
        iny
        cpy #NFD
        bne @fd
        ; free memory
        ldx cur
        lda p_mpage,x
        ldy p_mlen,x
        jsr page_free
        ; reparent children to init (slot of pid 1)
        jsr find_init
        stx tmp2
        ldy #MAXPROC-1
@ch:    lda p_state,y
        beq @chn
        lda p_pslot,y
        cmp cur
        bne @chn
        lda tmp2
        sta p_pslot,y
        lda #1
        sta p_ppid,y
@chn:   dey
        bpl @ch
        lda #CH_CHILD
        ora tmp2
        jsr wakeup          ; init may have new zombies to reap
        ldx cur
        lda #PS_ZOMBIE
        sta p_state,x
        lda p_pslot,x
        ora #CH_CHILD
        jsr wakeup
        jsr sched           ; does not return: zombies are never resumed

; find_init: X = slot of pid 1
find_init:
        ldx #MAXPROC-1
@l:     lda p_state,x
        beq @n
        lda p_pid,x
        cmp #1
        beq @r
@n:     dex
        bpl @l
@r:     rts

; find_pid: A = pid -> X = slot, carry clear; carry set if none
find_pid:
        ldx #MAXPROC-1
@l:     ldy p_state,x
        beq @n
        cmp p_pid,x
        beq @f
@n:     dex
        bpl @l
        sec
        rts
@f:     clc
        rts

; ---- syscalls ----
sys_exit:
        and #$7f
        jmp proc_exit

; wait(A = pid or $FF, X = flags) -> A = pid, X = exit code
sys_wait:
        sta sb0
        stx sb1
@again: lda #0
        sta sb2             ; found a matching child
        ldy #MAXPROC-1
@l:     lda p_state,y
        beq @n
        lda p_pslot,y
        cmp cur
        bne @n
        lda sb0
        cmp #$ff
        beq @m
        cmp p_pid,y
        bne @n
@m:     inc sb2
        lda p_state,y
        cmp #PS_ZOMBIE
        bne @n
        lda #PS_FREE
        sta p_state,y
        lda p_pid,y
        ldx p_exit,y
        clc
        rts
@n:     dey
        bpl @l
        lda sb2
        bne @wait
        lda #ECHILD
        sec
        rts
@wait:  lda sb1
        and #W_NOHANG
        beq @blk
        lda #0
        clc
        rts
@blk:   lda cur
        ora #CH_CHILD
        jsr block_on
        jmp @again

; kill(A = pid, X = signal)
sys_kill:
        stx tmp0
        cmp #1
        beq @perm
        jsr find_pid
        bcs @srch
        lda p_state,x
        cmp #PS_ZOMBIE
        beq @srch
        lda tmp0
        beq @ok
        sta p_sig,x
        lda p_state,x
        cmp #PS_BLOCKED
        bne @ok
        lda #PS_READY
        sta p_state,x
@ok:    clc
        rts
@perm:  lda #EPERM
        sec
        rts
@srch:  lda #ESRCH
        sec
        rts

sys_getpid:
        ldx cur
        lda p_pid,x
        clc
        rts

sys_yield:
        jsr sched
        clc
        rts

; sleep(A/X = jiffies)
sys_sleep:
        sei
        clc
        adc ticks
        sta sb0
        txa
        adc ticks+1
        sta sb1
        lda ticks+2
        adc #0
        sta sb2
        cli
@l:     sei
        lda ticks
        cmp sb0
        lda ticks+1
        sbc sb1
        lda ticks+2
        sbc sb2
        cli
        bcs @done
        lda #CH_TICK
        jsr block_on
        jmp @l
@done:  clc
        rts

; time() -> A/X/Y = jiffies lo/mid/hi
sys_time:
        sei
        lda ticks
        ldx ticks+1
        ldy ticks+2
        cli
        clc
        rts

; procinfo(A = slot, r0 = buf[16]): pid ppid state flags pages name[11]
sys_procinfo:
        cmp #MAXPROC
        bcs @no
        tax
        lda p_state,x
        beq @no
        ldy #0
        lda p_pid,x
        sta (r0),y
        iny
        lda p_ppid,x
        sta (r0),y
        iny
        lda p_state,x
        sta (r0),y
        iny
        lda p_flags,x
        sta (r0),y
        iny
        lda p_mlen,x
        sta (r0),y
        ; name
        txa
        jsr name_off
        tax
        ldy #5
@nl:    lda p_name,x
        sta (r0),y
        inx
        iny
        cpy #16
        bne @nl
        clc
        rts
@no:    sec
        lda #ESRCH
        rts

; name_off: A = slot -> A = slot * NAMELEN (11)
name_off:
        sta tmp0
        asl a
        asl a
        clc
        adc tmp0            ; *5
        asl a               ; *10
        clc
        adc tmp0            ; *11
        rts
.export name_off, find_init
