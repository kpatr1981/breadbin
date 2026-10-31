; Breadbin syscall entry: fixed jump table at $CF00 and dispatcher
;
; Programs `jsr SYS_x`; the table entry jumps to a stub that records the
; syscall number, then `dispatch` marks the kernel busy and calls the
; handler. Handlers return carry/A/X/r-registers; `sys_return` acts on
; pending signals and deferred reschedules before going back to user code.
.include "k.inc"
.import sys_isatty, sys_conmode, sys_getuid, sys_setuid, sys_mount, sys_umount, sys_mntinfo, sys_diskio, sys_fg
.import sys_sync, bflush_due
.import ul_print, ul_eprint, ul_fprint, ul_putc, ul_eputc, ul_fputc
.import ul_newline, ul_print_dec, ul_print_dec_w, ul_print_hex, ul_dec_str
.import ul_parse_dec, ul_strlen, ul_strcmp, ul_argn, ul_perr, ul_errstr
.import ul_open_or_die, ul_basename

NSYS = 33
STUBSZ = 8

.segment "JUMPTAB"
.repeat NSYS, I
        jmp stubs + I*STUBSZ
.endrep
; the user library (ulib.s): straight jumps, in the order of breadbin.inc
        jmp ul_print        ; 33
        jmp ul_eprint
        jmp ul_fprint
        jmp ul_putc
        jmp ul_eputc
        jmp ul_fputc
        jmp ul_newline
        jmp ul_print_dec    ; 40
        jmp ul_print_dec_w
        jmp ul_print_hex
        jmp ul_dec_str
        jmp ul_parse_dec
        jmp ul_strlen
        jmp ul_strcmp
        jmp ul_argn
        jmp ul_perr         ; 48
        jmp ul_errstr
        jmp ul_open_or_die
        jmp ul_basename

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
        pha
        txa
        pha
        jsr bflush_due      ; changed blocks reach the disk within ~2 s
        sei
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
        .lobytes sys_procinfo-1, sys_meminfo-1, sys_fsinfo-1, sys_time-1, sys_isatty-1, sys_conmode-1
        .lobytes sys_getuid-1, sys_setuid-1, sys_mount-1, sys_umount-1, sys_mntinfo-1, sys_diskio-1
        .lobytes sys_fg-1, sys_sync-1
sys_hi: .hibytes sys_exit-1, sys_spawn-1, sys_wait-1, sys_kill-1, sys_getpid-1
        .hibytes sys_yield-1, sys_sleep-1, sys_open-1, sys_close-1, sys_read-1
        .hibytes sys_write-1, sys_pipe-1, sys_mkdir-1, sys_rmdir-1, sys_unlink-1
        .hibytes sys_rename-1, sys_chdir-1, sys_getcwd-1, sys_stat-1
        .hibytes sys_procinfo-1, sys_meminfo-1, sys_fsinfo-1, sys_time-1, sys_isatty-1, sys_conmode-1
        .hibytes sys_getuid-1, sys_setuid-1, sys_mount-1, sys_umount-1, sys_mntinfo-1, sys_diskio-1
        .hibytes sys_fg-1, sys_sync-1
