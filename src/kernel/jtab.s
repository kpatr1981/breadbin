; c64os syscall entry: fixed jump table at $CF00 and dispatcher
;
; Programs `jsr SYS_x`; the table entry jumps to a stub that records the
; syscall number, then `dispatch` marks the kernel busy and calls the
; handler. Handlers return carry/A/X/r-registers; `sys_return` acts on
; pending signals and deferred reschedules before going back to user code.
.include "k.inc"
.import sys_isatty

NSYS = 24
STUBSZ = 8

.segment "JUMPTAB"
.repeat NSYS, I
        jmp stubs + I*STUBSZ
.endrep

.segment "CODE"
stubs:
.repeat NSYS, I
        sei
        sta k_a
        lda #I
        jmp dispatch
.endrep

dispatch:
        sta k_n
        lda #1
        sta in_kernel
        stx k_x
        lda #>(sys_return-1)
        pha
        lda #<(sys_return-1)
        pha
        ldx k_n
        lda sys_hi,x
        pha
        lda sys_lo,x
        pha
        ldx k_x
        lda k_a
        cli
        rts

sys_return:
        php
        sei
        pha
        txa
        pha
        jsr check_signal
        lda need_resched
        beq @out
        lda #0
        sta need_resched
        jsr sched
        jsr check_signal
@out:   lda #0
        sta in_kernel
        pla
        tax
        pla
        plp
        rts

.segment "RODATA"
sys_lo: .lobytes sys_exit-1, sys_spawn-1, sys_wait-1, sys_kill-1, sys_getpid-1
        .lobytes sys_yield-1, sys_sleep-1, sys_open-1, sys_close-1, sys_read-1
        .lobytes sys_write-1, sys_pipe-1, sys_mkdir-1, sys_rmdir-1, sys_unlink-1
        .lobytes sys_rename-1, sys_chdir-1, sys_getcwd-1, sys_stat-1
        .lobytes sys_procinfo-1, sys_meminfo-1, sys_fsinfo-1, sys_time-1, sys_isatty-1
sys_hi: .hibytes sys_exit-1, sys_spawn-1, sys_wait-1, sys_kill-1, sys_getpid-1
        .hibytes sys_yield-1, sys_sleep-1, sys_open-1, sys_close-1, sys_read-1
        .hibytes sys_write-1, sys_pipe-1, sys_mkdir-1, sys_rmdir-1, sys_unlink-1
        .hibytes sys_rename-1, sys_chdir-1, sys_getcwd-1, sys_stat-1
        .hibytes sys_procinfo-1, sys_meminfo-1, sys_fsinfo-1, sys_time-1, sys_isatty-1
