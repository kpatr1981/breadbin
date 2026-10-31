; Breadbin kernel internal definitions
.include "../../include/breadbin.inc"

KSTART  = $7800     ; must match KRAM in kernel.cfg
MAXPROC = 12
NFD     = 8         ; fds per process
NFILE   = 24        ; system open-file table
NPIPE   = 4
NBUF    = 6         ; block cache buffers
NDEV    = 5         ; 0 drive 8, 1 REU, 2-4 drives 9-11
NMNT    = 4         ; mount table entries
FS_C64  = 0
FS_CBM  = 1
FT_CBMW = 7         ; open-file type: write to a CBM DOS file
ZPSAVE  = $3E       ; bytes $02-$3F saved per process
STKSAVE = 130       ; max saved stack bytes per process
SAVESZ  = ZPSAVE + STKSAVE   ; 192
CWDLEN  = 48
NAMELEN = 11
SLICE   = 3         ; ticks per time slice

; process states
PS_FREE    = 0
PS_READY   = 1
PS_BLOCKED = 2
PS_ZOMBIE  = 3
PS_STOPPED = 4

; p_flags beyond the spawn flags (SP_BG, SP_IGNINT)
PF_STOPREP = $20    ; stop already reported by wait
PF_STOP    = $40    ; stop pending (CTRL-Z, SIGTSTP, SIGSTOP)

; wait channels
CH_KEY   = $01      ; woken by the IRQ while keys are waiting (console)
CH_SLEEP = $02      ; woken when ticks reach p_wk (sleep)
CH_CHILD = $80      ; | parent slot
CH_PIPE  = $40      ; | pipe index

; file types (open-file table)
FT_FREE   = 0
FT_FILE   = 1
FT_DIR    = 2
FT_PIPER  = 3
FT_PIPEW  = 4
FT_CON    = 5
FT_NULL   = 6

; device majors
MAJ_NULL = 0
MAJ_CON  = 1

; c64fs
SB_MAGIC_LEN = 5
INO_SIZE   = 32
NDIRECT    = 12
DIRENT     = 16
NAME_MAX   = 14
ROOT_INO   = 1
I_TYPE  = 0
I_NLINK = 1
I_SIZE  = 2
I_MAJOR = 5
I_DIRECT = 6
I_INDIR = 30

; ZP scratch saved per process ($08-$1F); r0-r2 are $02-$07
r3 = $08
s0 = $0A
s1 = $0C
s2 = $0E
s3 = $10
s4 = $12
sb0 = $14
sb1 = $15
sb2 = $16
sb3 = $17
sb4 = $18
sb5 = $19
sb6 = $1A
sb7 = $1B
k_entry = $1E

; KERNAL
CHROUT = $FFD2
GETIN  = $FFE4
CHKIN  = $FFC6
CHKOUT = $FFC9
CHRIN  = $FFCF
CLRCHN = $FFCC
SETLFS = $FFBA
SETNAM = $FFBD
OPEN   = $FFC0
CLOSE  = $FFC3
UDTIM  = $FFEA
SCNKEY = $FF9F
ST     = $90

; ---- shared symbols ----
; zero page globals (main.s)
.globalzp cur, in_kernel, need_resched, slice, ticks, p1, p2, p3, p4
.globalzp k_a, k_x, k_n, k_vec, tmp0, tmp1, tmp2, tmp3, stop_prev, intr_pending

; main.s
.global kmain, panic, pool_first, pool_last
; con.s
.global con_init, con_putc, con_puts_ax, con_write, con_read, con_hex, con_dec
.global con_cursor_tick, con_eof
; proc.s
.global irq, sched, block_on, wakeup, proc_exit, sys_exit, sys_wait, sys_kill
.global sys_getpid, sys_yield, sys_sleep, sys_procinfo, sys_time
.global p_state, p_pid, p_ppid, p_flags, p_chan, p_sp, p_mpage, p_mlen
.global p_sig, p_exit, p_name, p_fd, p_cwd, p_cwdino, p_cwddev, p_save
.global next_pid, proc_init, slot_save_ptr, check_signal
; mem.s
.global page_alloc, page_free, mem_init, sys_meminfo, free_pages, total_pages
; blk.s
.global blk_init, bread, bdirty, bflush_all, buf_ptr, reu_banks, ram_type, dev_present
.global iec_open, iec_close, ts_block, iec_command, cur_dev_set, dev_drive, dev_type
.global bget_buf, binval
.global ieclisten, iectalk, iecout, iecin, iecunlisten, iecuntalk, iec_init
.global ie_st
; fs.s
.global fs_mount, iget, iput, ci, ci_dev, ci_ino, bmap, namei, nameiparent
.global fs_name, dir_lookup, dir_add, dir_remove, ialloc, itrunc, balloc
.global fs_read, fs_write, f_off, f_cnt, f_buf, dir_empty, fs_mkfs_reu
.global mnt_active, mnt_ino, sb_nblocks, sb_ninodes, fs_count_free
; file.s
.global file_init, fd_get, oft_alloc, oft_ref, oft_unref, fd_alloc
.global f_type, f_ref, f_flags, f_dev, f_ino, f_pos0, f_pos1, f_pos2, f_pipe
.global sys_open, sys_close, sys_read, sys_write, sys_pipe, sys_mkdir
.global sys_rmdir, sys_unlink, sys_rename, sys_chdir, sys_getcwd, sys_stat
.global sys_fsinfo, con_file
; exec.s
.global sys_spawn, spawn_kernel
; util
.global strlen_r0, copy_name
