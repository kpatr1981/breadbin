; Breadbin processes: table, scheduler, context switch, IRQ, signals
;
; Context switch model: the kernel is not preemptible (in_kernel != 0);
; user code is. Every saved context lives inside a call to `sched`: it
; pushes P, saves SP, ZP $02-$3F and the used part of the stack page into
; the process's save area, then restores another process the same way and
; returns (plp/rts) into *that* process's call to sched.
.include "k.inc"
.import con_raw
.export sys_fg, tod_soft, sigint_fg, sigtstp_fg, tod_tick

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
p_uid:    .res MAXPROC
p_pgrp:   .res MAXPROC      ; job (process group): the pid of its first process
p_wk0:    .res MAXPROC      ; sleep deadline (jiffies)
p_wk1:    .res MAXPROC
p_wk2:    .res MAXPROC
p_name:   .res MAXPROC*NAMELEN
p_fd:     .res MAXPROC*NFD
p_cwd:    .res MAXPROC*CWDLEN
p_save:   .res MAXPROC*SAVESZ
next_pid: .res 1
new_slot: .res 1
wk_ch:    .res 1
fg_sig:   .res 1
tod_soft: .res 1        ; 0 unchecked, 1 TOD ticks, $80 the IRQ ticks it
tod_div:  .res 1
tod_h:    .res 1
tod_m:    .res 1
tod_s:    .res 1
tod_t:    .res 1

.export p_pslot, new_slot, proc_entry, p_uid, sys_getuid, sys_setuid, p_pgrp

.segment "RODATA"
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
        ; the process overflowed its stack area: it cannot be saved, kill it
        lda #128+11
        jmp proc_exit
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
; Callers loop: block_on may return early (a signal, a stop and continue).
block_on:
        pha
        jsr check_signal
        pla
        bcs @r              ; was stopped: let the caller look again
        ldx cur
        sta p_chan,x
        lda #PS_BLOCKED
        sta p_state,x
        jsr sched
        jmp check_signal
@r:     rts

; check_signal: if the current process has a pending signal, it exits; if
; it has a pending stop, it stops until continued (then carry set).
check_signal:
        ldx cur
        lda p_sig,x
        bne @die
        lda p_flags,x
        and #PF_STOP
        beq @r
        jsr do_stop
        ldx cur
        lda p_sig,x
        bne @die
        sec
        rts
@r:     clc
        rts
@die:   ora #$80
        jmp proc_exit

; do_stop: stop the current process (it leaves the foreground) and tell
; its parent. Returns once SIGCONT or fg makes it ready again.
do_stop:
        ldx cur
        lda p_flags,x
        and #<~(PF_STOP | PF_STOPREP)
        ora #SP_BG
        sta p_flags,x
        lda #PS_STOPPED
        sta p_state,x
        lda p_pslot,x
        ora #CH_CHILD
        jsr wakeup
        jmp sched

; wakeup: A = channel. Make every process blocked on it ready.
wakeup:
        php
        sei                 ; the IRQ calls wakeup too: keep wk_ch ours
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
        plp
        rts

; ---------------------------------------------------------------------
irq:
        cld
        inc in_irq
        lda $dc0d           ; acknowledge CIA1 timer
        jsr UDTIM
        jsr SCNKEY
        inc ticks
        bne @t
        inc ticks+1
        bne @t
        inc ticks+2
@t:     jsr tod_tick
        jsr con_cursor_tick
        ; wake sleepers whose deadline has passed
        ldx #MAXPROC-1
@sl:    lda p_state,x
        cmp #PS_BLOCKED
        bne @sn
        lda p_chan,x
        cmp #CH_SLEEP
        bne @sn
        lda ticks
        cmp p_wk0,x
        lda ticks+1
        sbc p_wk1,x
        lda ticks+2
        sbc p_wk2,x
        bcc @sn
        lda #PS_READY
        sta p_state,x
@sn:    dex
        bpl @sl
        ; RUN/STOP in the keyboard buffer -> SIGINT (and drop the key);
        ; CTRL-Z -> SIGTSTP, unless a raw-mode program wants the key
        ldx $c6
        beq @nokb
        lda $0276,x
        cmp #$03
        bne @noc
        dec $c6
        jsr sigint_fg
        jmp @nokb
@noc:   cmp #$1a
        bne @nokb
        lda con_raw
        bne @nokb
        dec $c6
        jsr sigtstp_fg
@nokb:  lda restore_pending ; RESTORE while the kernel ran: kill the job now
        beq @nores
        lda #0
        sta restore_pending
        jsr sigkill_fg
@nores: ; keys left in the buffer: wake the console readers
        lda $c6
        beq @nokey
        lda #CH_KEY
        jsr wakeup
@nokey: ; RUN/STOP edge -> SIGINT to foreground processes
        lda $91
        cmp #$7f
        bne @nostop
        cmp stop_prev
        beq @stopd
        sta stop_prev
        jsr sigint_fg
        jmp @stopd
@nostop: sta stop_prev
@stopd: dec in_irq
        lda in_kernel
        bne @kern
        ldx cur
        cpx #$ff
        beq @out
        lda p_sig,x
        bne @die
        lda p_flags,x
        and #PF_STOP
        beq @nstp
        lda #1
        sta in_kernel
        jsr check_signal
        lda #0
        sta in_kernel
        jmp @out
@nstp:  dec slice
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

; tod_tick: CIA 1's TOD clock counts the mains frequency on its TOD pin.
; On a C64 fed from a DC supply that pin is dead and TOD stands still, so
; half a second after boot (kmain started it at 00:00:00.0) the IRQ checks:
; if it has not moved, every 6th jiffy adds a tenth of a second instead.
; The registers stay the clock, so `date` and programs read and set it as
; on any C64.
tod_tick:
        lda tod_soft
        bmi @soft
        bne @r              ; checked: TOD ticks by itself
        lda ticks
        cmp #30
        bne @r
        lda $dc09           ; seconds, then tenths (no latch)
        ora $dc08
        bne @hw
        lda #6
        sta tod_div
        lda #$80
        .byte $2c
@hw:    lda #1
        sta tod_soft
@r:     rts
@soft:  dec tod_div
        bne @r
        lda #6
        sta tod_div
        lda $dc0b           ; reading hours latches, tenths unlatches
        sta tod_h
        lda $dc0a
        sta tod_m
        lda $dc09
        sta tod_s
        lda $dc08
        sed
        clc
        adc #1
        cmp #$10
        bcc @set            ; A = tenths
        lda tod_s
        adc #0              ; carry is set: +1
        sta tod_s
        cmp #$60
        bcc @z
        lda #0
        sta tod_s
        lda tod_m
        adc #0
        sta tod_m
        cmp #$60
        bcc @z
        lda #0
        sta tod_m
        lda tod_h           ; 12-hour BCD, bit 7 = PM
        and #$1f
        adc #0
        cmp #$13
        bcc @h
        lda #$01
@h:     sta tod_t
        lda tod_h
        and #$80
        ldx tod_t
        cpx #$12            ; 11 -> 12 flips AM/PM
        bne @k
        eor #$80
@k:     ora tod_t
        sta tod_h
@z:     lda #0
@set:   cld
        pha
        lda tod_h
        jsr tod_wh
        pla
        ldx tod_m
        stx $dc0a
        ldx tod_s
        stx $dc09
        sta $dc08           ; writing tenths starts it
        rts

; tod_wh: write A to the TOD hours (this stops the clock). The 6526 flips
; AM/PM when 12 is written, so 12 goes in with the flag inverted.
tod_wh:
        tax
        and #$7f
        eor #$12
        bne @w
        txa
        eor #$80
        tax
@w:     stx $dc0b
        rts

; sigint_fg / sigtstp_fg / sigkill_fg: interrupt, stop or kill the
; foreground processes
sigkill_fg:
        lda #SIGKILL
        .byte $2c           ; bit abs: skip the next lda
sigtstp_fg:
        lda #SIGTSTP
        .byte $2c           ; bit abs: skip the next lda
sigint_fg:
        lda #SIGINT
        sta fg_sig
        ldx #MAXPROC-1
@l:     lda p_state,x
        cmp #PS_READY
        beq @y
        cmp #PS_BLOCKED
        bne @n
@y:     lda p_flags,x
        and #(SP_BG | SP_IGNINT)
        bne @n
        lda fg_sig
        cmp #SIGTSTP
        beq @stop
        sta p_sig,x
        bne @rdy
@stop:  lda p_flags,x
        ora #PF_STOP
        sta p_flags,x
@rdy:   lda #PS_READY
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
        .import con_release
        jsr con_release     ; A = pid: leave raw console mode
        ldx cur
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
        lda p_state,y       ; a stopped orphan would wait forever: hang it up
        cmp #PS_STOPPED
        bne @chn
        lda #SIGHUP
        sta p_sig,y
        lda #PS_READY
        sta p_state,y
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

; wait(A = pid or $FF, X = flags) -> A = pid, X = exit code (WSTOPPED: it
; stopped, reported once with W_UNTRACED). W_JOB: A is a job, not a pid.
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
        lda sb1
        and #W_JOB
        beq @pid
        lda sb0
        cmp p_pgrp,y
        bne @n
        beq @m
@pid:   lda sb0
        cmp p_pid,y
        bne @n
@m:     inc sb2
        lda p_state,y
        cmp #PS_ZOMBIE
        beq @reap
        cmp #PS_STOPPED
        bne @n
        lda sb1
        and #W_UNTRACED
        beq @n
        lda p_flags,y
        and #PF_STOPREP
        bne @n
        lda p_flags,y
        ora #PF_STOPREP
        sta p_flags,y
        lda p_pid,y
        ldx #WSTOPPED
        clc
        rts
@reap:  lda #PS_FREE
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
        jsr may_signal
        bcs @perm
        lda tmp0
        beq @ok
        cmp #SIGCONT
        beq @cont
        cmp #SIGSTOP
        beq @stop
        cmp #SIGTSTP
        beq @stop
        sta p_sig,x
@wake:  lda p_state,x       ; blocked or stopped: run, to act on it
        cmp #PS_BLOCKED
        bcc @ok
        lda #PS_READY
        sta p_state,x
@ok:    clc
        rts
@stop:  lda p_state,x
        cmp #PS_STOPPED
        beq @ok
        lda p_flags,x
        ora #PF_STOP
        sta p_flags,x
        bne @wake
@cont:  jsr cont_slot
        clc
        rts
@perm:  lda #EPERM
        sec
        rts
@srch:  lda #ESRCH
        sec
        rts

; fg(A = job, X = 1): continue every process of the job in the
; foreground; X = 0 (bg): continue it in the background
sys_fg:
        sta tmp0
        stx tmp1
        lda #0
        sta tmp2            ; processes found
        ldx #MAXPROC-1
@l:     lda p_state,x
        beq @n
        cmp #PS_ZOMBIE
        beq @n
        lda p_pgrp,x
        cmp tmp0
        bne @n
        jsr may_signal
        bcs @n
        inc tmp2
        lda tmp1
        beq @c
        lda p_flags,x
        and #<~SP_BG
        sta p_flags,x
@c:     jsr cont_slot
@n:     dex
        bpl @l
        lda tmp2
        beq @srch
        clc
        rts
@srch:  lda #ESRCH
        sec
        rts

; cont_slot: X = slot. Continue it (SIGCONT).
cont_slot:
        lda p_flags,x
        and #<~(PF_STOP | PF_STOPREP)
        sta p_flags,x
        lda p_state,x
        cmp #PS_STOPPED
        bne @r
        lda #PS_READY
        sta p_state,x
@r:     rts

; may_signal: X = slot -> carry set if the current user may not signal it
; (only root signals other users' processes). Uses Y.
may_signal:
        ldy cur
        lda p_uid,y
        beq @ok
        cmp p_uid,x
        bne @no
@ok:    clc
        rts
@no:    sec
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
        ldy cur
        sei
        clc
        adc ticks
        sta p_wk0,y
        txa
        adc ticks+1
        sta p_wk1,y
        lda ticks+2
        adc #0
        sta p_wk2,y
        cli
@l:     ldy cur
        sei
        lda ticks
        cmp p_wk0,y
        lda ticks+1
        sbc p_wk1,y
        lda ticks+2
        sbc p_wk2,y
        cli
        bcs @done
        lda #CH_SLEEP
        jsr block_on
        jmp @l
@done:  clc
        rts

; getuid() -> A = uid
sys_getuid:
        ldx cur
        lda p_uid,x
        clc
        rts

; setuid(A = uid): only uid 0 (root) may change it
sys_setuid:
        ldx cur
        ldy p_uid,x
        bne @perm
        sta p_uid,x
        clc
        rts
@perm:  cmp p_uid,x
        beq @ok
        lda #EPERM
        sec
        rts
@ok:    clc
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

; procinfo(A = slot, r0 = buf[17]): pid ppid state flags pages name[11] uid
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
        ldx tmp0            ; slot (name_off kept it)
        lda p_uid,x
        sta (r0),y
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
.export name_off, find_init, find_pid
