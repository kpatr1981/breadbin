; Breadbin serial terminal: /dev/ttyS0 on a SwiftLink or Turbo232 cartridge
; (a 6551 ACIA at $DE00, interrupting through the NMI line).
;
; Terminal 0 is the console (screen and keyboard), terminal 1 the serial
; line. A process's terminal is that of its standard input, or its
; parent's (tty_of); CTRL-C / CTRL-Z typed on a terminal go to that
; terminal's foreground processes only. docs/terminal.md is the user's
; guide, docs/design-tty.md the design.
;
; Kernel RAM is full, so almost nothing of this lives there. Each hook in
; the kernel is one `jsr` into code that is copied at boot to RAM the
; KERNAL leaves alone (Breadbin never uses tape):
;   LOWCODE  $0334-$03FF  the cassette buffer: the hooks
;   LOWDATA  $02A7-$02FF  unused by the KERNAL: variables, more hooks
;   JTCODE   the end of the $CF00 jump table page: tcall, tty_hold, read/write
;   HICODE / TTYBSS  under the KERNAL ROM: the driver, the rings, the line
;            discipline and the ANSI translation, called with tcall
;
; The NMI handler (main.s) calls tty_nmihook, which serves the ACIA through
; tty_nmi: bytes go between the chip and two 128-byte rings, and only
; flags are raised. The 60 Hz IRQ calls tty_tick (tty_irqhook), which acts
; on them: wakeups, signals, hangup (an NMI can interrupt the IRQ in the
; middle of wakeup, so the NMI never calls it).
;
; Disk transfers are timed to the cycle: an NMI in one breaks it. The
; serial bus code calls tty_hold before each step; it turns the receive
; interrupt and RTS off (the other side should stop sending; the chip
; keeps one byte) for 3 jiffies, renewed on every call.
.include "k.inc"
.import bg_stop, fd_install, sigint_fg, sigtstp_fg, p_pslot

ACIA_DATA = $de00
ACIA_ST   = $de01       ; bit 7 IRQ, 5 DCD (1 = no carrier), 4 TDRE, 3 RDRF
ACIA_CMD  = $de02
ACIA_CTL  = $de03
CMD_IDLE  = $09         ; DTR, receive IRQ on, RTS on, transmit IRQ off
CMD_SEND  = $05         ; the same, and transmit IRQ on
CMD_HOLD  = $03         ; receive IRQ off, RTS off, transmit IRQ off
CTL_SPEED = $1c         ; 8N1, internal clock, 9600 baud on a SwiftLink
HOLDJ     = 3           ; jiffies a hold lasts after the last bus step
LBMAX     = 79
RMASK     = $7f         ; rings of 128 bytes
TXNEED    = 8           ; room one translated byte may need (ESC [ 2 5 ; 4 0 H)

.export tty_boot, tty_init, tty_hold, tty_read, tty_write
.export tty_nmihook, tty_irqhook, tty_sigchk, tty_chrhook, tty_athook
.export tty_rdhook, tty_wrhook, tty_cmhook, tty_on

; ---------------------------------------------------------------------
; LOWDATA ($02A7-$02FF): variables (copied at boot: all start at 0)
.segment "LOWDATA"
tty_on:   .byte 0       ; bit 7: a card was found at boot
tty_st:   .byte 0       ; ACIA status, as the NMI hook read it
tvec:     .word 0       ; tcall's target
hold_cnt: .byte 0       ; jiffies left of a disk hold (0 = none)
fg_tty:   .byte 0       ; the terminal sigint_fg / sigtstp_fg act on
t_x:      .byte 0

; tty_of: X = process slot -> A = its terminal (0 console, 1 serial; Z set
; for 0): its stdin's, else its parent's, up to init (the console). Orphans
; get init as their parent (proc_exit), so the chain always ends. Keeps X
; (on the stack: the NMI may call it while another call is running); uses Y.
tty_of: txa
        pha
@up:    txa
        asl a
        asl a
        asl a               ; NFD = 8 descriptors a process
        tay
        lda p_fd,y
        cmp #$ff
        beq @par
        tay
        lda f_type,y
        cmp #FT_TTY
        beq @ser
        cmp #FT_CON
        beq @con
@par:   lda p_pslot,x
        tax
        bpl @up             ; $ff: init's parent: the console
@con:   pla
        tax
        lda #0
        rts
@ser:   pla
        tax
        lda #1
        rts

; tty_irqhook: from the IRQ, every jiffy
tty_irqhook:
        bit tty_on
        bpl @r
        lda #<tty_tick
        ldx #>tty_tick
        jmp tcall
@r:     rts

; tty_athook: in sys_isatty, after `lda f_type,x`: the serial line is a
; terminal too. X = which: 0 the console, 1 the serial line.
tty_athook:
        ldx #0
        cmp #FT_TTY
        bne @r
        inx
        lda #FT_CON
@r:     rts

; tty_rdhook: in sys_read, A = the file's type
tty_rdhook:
        cmp #FT_TTY
        bne @r
        pla
        pla
        jmp tty_read
@r:     rts

; ---------------------------------------------------------------------
; LOWCODE ($0334-$03FF): the hooks
.segment "LOWCODE"

; tty_nmihook: first thing in nmi_handler (A and X pushed). Serves the ACIA
; and returns from the NMI itself; or returns to the RESTORE code.
tty_nmihook:
        bit tty_on
        bpl @rst
        lda ACIA_ST         ; reading it releases the chip's line
        bmi @acia
        lda hold_cnt        ; just put on hold for the disk: a late ACIA
        bne @done           ; NMI, not RESTORE
@rst:   ldx cur             ; RESTORE while a serial-line process runs: not
        cpx #$ff            ; that one: the console's job, at the next IRQ
        beq @r
        tya
        pha
        jsr tty_of
        tax
        pla
        tay
        txa
        beq @r
        lda #$7f            ; (CIA 2 NMIs off and acknowledged, as RESTORE does)
        sta $dd0d
        lda $dd0d
        lda #1
        sta restore_pending
        bne @done
@acia:  sta tty_st
        lda $01
        pha
        lda #MAP_RAM
        sta $01
        jsr tty_nmi
        pla
        sta $01
@done:  pla                 ; our return address
        pla
        pla                 ; the handler's X and A
        tax
        pla
        rti
@r:     rts

; tty_sigchk: in sigint_fg's loop, in place of its `lda p_state,x`: a
; process of another terminal looks free there, so it is passed over.
; A free slot is never followed up the parents: its parent slot is stale,
; and two stale slots can point at each other (an endless loop in the IRQ).
tty_sigchk:
        lda p_state,x
        beq @r
        tya
        pha
        jsr tty_of
        cmp fg_tty
        bne @no
        pla
        tay
        lda p_state,x
        rts
@no:    pla
        tay
        lda #PS_FREE
@r:     rts

; tty_chrhook: in sys_open, after `lda ci+I_MAJOR` of a device (X = the
; open-file entry). /dev/ttyS0 is opened here; /dev/tty is the caller's own
; terminal: the console's major goes back for it, or it is /dev/ttyS0.
tty_chrhook:
        cmp #MAJ_CTTY
        bne @c1
        stx t_x
        ldx cur
        jsr tty_of
        ldx t_x
        cmp #0
        bne @ser
        lda #MAJ_CON
        rts
@c1:    cmp #MAJ_TTY
        beq @ser
        rts
@ser:   pla                 ; the open ends here
        pla
        bit tty_on
        bmi @on
        txa                 ; no card
        jsr oft_unref
        lda #ENODEV
        sec
        rts
@on:    lda #FT_TTY
        sta f_type,x
        jmp fd_install

; tty_wrhook: in sys_write, A = the file's type (tty_rdhook: in LOWDATA)
tty_wrhook:
        cmp #FT_TTY
        bne @r
        pla
        pla
        jmp tty_write
@r:     rts

; tty_cmhook: first thing in sys_conmode (A = mode): with stdin on the
; serial line, set its mode and return from the system call
tty_cmhook:
        pha
        lda #0
        jsr fd_get
        bcs @no
        lda f_type,x
        cmp #FT_TTY
        bne @no
        pla
        and #1
        tay
        pla
        pla
        lda #<tty_mode
        ldx #>tty_mode
        jsr tcall
        clc
        rts
@no:    pla
        rts

; ---------------------------------------------------------------------
; JTCODE: the end of the jump table page
.segment "JTCODE"

; tcall: A/X = a routine under the ROM, Y = its argument. Runs it with
; interrupts off and the ROM switched out. Returns its A (Z/N set from it);
; X is lost, carry is the caller's.
tcall:  php
        sei
        sta tvec
        stx tvec+1
        lda #MAP_RAM
        sta $01
        jsr @j
        ldx #MAP_KERNAL
        stx $01
        plp
        ora #0
        rts
@j:     jmp (tvec)

; tty_hold: from the serial bus code, before a step that is timed to the
; cycle. Keeps A, X, Y and carry.
tty_hold:
        bit tty_on
        bpl @r
        pha
        lda #HOLDJ
        sta hold_cnt        ; first: the NMI must not turn it back on
        lda #CMD_HOLD
        sta ACIA_CMD
        pla
@r:     rts

; tty_read / tty_write: read and write on /dev/ttyS0 (r0, r1 as theirs).
; tty_rw does as much as it can; when it can't go on (no complete line, or
; the send ring is full) the caller sleeps until tty_tick wakes it. sb4
; (0 read, 1 write) and sb5 survive the sleep: they are saved per process.
tty_write:
        lda #1
        .byte $2c           ; bit abs: skip the lda #0
tty_read:
        lda #0
        sta sb4
        lda #0
        sta sb5
@w:     lda sb4
        bne @go             ; writing in the background is allowed
        jsr bg_stop
@go:    lda #<tty_rw
        ldx #>tty_rw
        jsr tcall
        bne @d
        lda #CH_TTY
        jsr block_on
        jmp @w
@d:     clc
        rts

; ---------------------------------------------------------------------
; boot
.import __LOWCODE_LOAD__, __LOWCODE_RUN__, __LOWCODE_SIZE__
.import __LOWDATA_LOAD__, __LOWDATA_RUN__, __LOWDATA_SIZE__
.segment "INIT"

; tty_boot: before the NMI vector is set: copy the hooks down
tty_boot:
        ldx #<__LOWCODE_SIZE__
@c:     lda __LOWCODE_LOAD__-1,x
        sta __LOWCODE_RUN__-1,x
        dex
        bne @c
        ldx #<__LOWDATA_SIZE__
@d:     lda __LOWDATA_LOAD__-1,x
        sta __LOWDATA_RUN__-1,x
        dex
        bne @d
        rts

; tty_init: find the card (after blk_init: not with GeoRAM, which has its
; window at $DE00 too)
tty_init:
        lda ram_type
        cmp #2
        beq @no
        lda #CTL_SPEED
        sta ACIA_CTL
        lda #$02            ; receive IRQ off, DTR still off (VICE connects
        sta ACIA_CMD        ; its TCP line when DTR goes on)
        lda ACIA_CTL        ; registers that keep what was written ...
        cmp #CTL_SPEED
        bne @no
        lda ACIA_CMD
        cmp #$02
        bne @no
        sta ACIA_ST         ; ... and a programmed reset clears command bits 0-4
        lda ACIA_CMD
        and #$1f
        bne @no             ; plain RAM (or nothing) would still read $02
        lda #CTL_SPEED
        sta ACIA_CTL
        php
        sei
        lda #MAP_RAM        ; TTYBSS is under the ROM: clear its variables
        sta $01             ; (the rings' contents don't matter)
        lda #0
        ldx #tty_end - rx_head - 1
@z:     sta rx_head,x
        dex
        bpl @z
        lda ACIA_ST
        and #$20
        sta t_dcd           ; DCD as it is now
        lda #MAP_KERNAL
        sta $01
        plp
        lda #CMD_IDLE
        sta ACIA_CMD
        lda #$80
        sta tty_on
@no:    rts

; ---------------------------------------------------------------------
; under the KERNAL ROM
.segment "TTYBSS"
rx_buf:   .res 128
tx_buf:   .res 128
lbuf:     .res LBMAX+1  ; the line being typed (cooked mode)
rx_head:  .res 1        ; written by the NMI
rx_tail:  .res 1
tx_head:  .res 1
tx_tail:  .res 1        ; written by the NMI
lb_len:   .res 1
lb_rpos:  .res 1
lb_ready: .res 1
t_raw:    .res 1        ; 1 = raw keys (conmode on the serial line)
t_rawpid: .res 1
i_esc:    .res 1        ; input: 1 after ESC, 2 inside ESC [
i_cr:     .res 1        ; input: the last byte was CR (drop a following LF)
o_esc:    .res 1        ; output: 1 after ESC, 2 row, 3 column, 4-6 colours
o_row:    .res 1
t_dcd:    .res 1        ; DCD as last seen
tf_wake:  .res 1        ; flags from the NMI for tty_tick
tf_int:   .res 1
tf_stp:   .res 1
tf_hup:   .res 1
t_px:     .res 1
tty_end:

.segment "HICODE"

; tty_nmi: from tty_nmihook, ROM out, A and X saved (not Y), tty_st = the
; status it read (bit 7 set). Serve the chip until it lets go of the line:
; the NMI input reacts to an edge, so an interrupt that comes while we are
; here would be lost otherwise (and RESTORE with it).
tty_nmi:
@svc:   lda tty_st
        and #$08            ; a byte came in
        beq @tx
        lda ACIA_DATA
        cmp #$03            ; CTRL-C: SIGINT, never queued
        bne @nc
        sta tf_int
        bne @tx
@nc:    cmp #$1a            ; CTRL-Z: SIGTSTP, unless a raw reader wants it
        bne @put
        ldx t_raw
        bne @put
        sta tf_stp
        bne @tx
@put:   ldx rx_head
        sta rx_buf,x
        inx
        txa
        and #RMASK
        cmp rx_tail
        beq @tx             ; full: the byte is lost
        sta rx_head
        lda #1
        sta tf_wake
@tx:    lda tty_st
        and #$10            ; ready for the next byte to send
        beq @dcd
        lda hold_cnt
        bne @dcd            ; holding for the disk: leave the chip alone
        ldx tx_tail
        cpx tx_head
        beq @idle
        lda tx_buf,x
        sta ACIA_DATA
        inx
        txa
        and #RMASK
        sta tx_tail
        lda #1              ; a writer may be waiting for room
        sta tf_wake
        bne @dcd
@idle:  lda #CMD_IDLE       ; nothing left: transmit interrupt off
        sta ACIA_CMD
@dcd:   lda tty_st
        and #$20            ; carrier lost: hang up
        cmp t_dcd
        beq @next
        sta t_dcd
        cmp #0
        beq @next
        sta tf_hup
@next:  lda ACIA_ST
        sta tty_st
        bpl @out
        jmp @svc
@out:   rts

; tty_tick: every jiffy, from the IRQ (via tcall)
tty_tick:
        lda hold_cnt        ; a disk hold ends 3 quiet jiffies after its last step
        beq @w
        dec hold_cnt
        bne @w
        lda #CMD_IDLE
        ldx tx_head
        cpx tx_tail
        beq @i
        lda #CMD_SEND
@i:     sta ACIA_CMD
@w:     lda tf_wake
        beq @s1
        lda #0
        sta tf_wake
        lda #CH_TTY
        jsr wakeup
@s1:    lda #1              ; the signals: to the serial line's processes
        sta fg_tty
        lda tf_int
        beq @s2
        lda #0
        sta tf_int
        jsr sigint_fg
@s2:    lda tf_stp
        beq @s3
        lda #0
        sta tf_stp
        jsr sigtstp_fg
@s3:    lda #0
        sta fg_tty
        lda tf_hup
        beq @r
        lda #0
        sta tf_hup
        jmp hangup
@r:     rts

; hangup: the carrier went: SIGHUP to every process of the serial line
; (init then starts a new login there), and forget what was typed
hangup: ldx #MAXPROC-1
@l:     lda p_state,x       ; live processes only (tty_sigchk says why)
        cmp #PS_READY
        beq @k
        cmp #PS_BLOCKED
        beq @k
        cmp #PS_STOPPED
        bne @n
@k:     jsr tty_of
        beq @n
        lda #SIGHUP
        sta p_sig,x
        lda #PS_READY
        sta p_state,x
@n:     dex
        bpl @l
        lda rx_head
        sta rx_tail
        lda #0
        sta t_raw
        sta lb_len
        sta lb_rpos
        sta lb_ready
        sta i_esc
        sta o_esc
        rts

; tty_mode: Y = 0 cooked, 1 raw (conmode with stdin on the serial line)
tty_mode:
        sty t_raw
        ldx cur
        lda p_pid,x
        sta t_rawpid
        lda #0
        sta lb_len
        sta lb_rpos
        sta lb_ready
        sta i_esc
        rts

; raw_alive: raw mode belongs to the process that set it: once that one
; has gone (exited or was killed in raw mode), the line is cooked again
raw_alive:
        lda t_raw
        beq @r
        ldx #MAXPROC-1
@l:     lda p_state,x
        beq @n
        cmp #PS_ZOMBIE
        beq @n
        lda p_pid,x
        cmp t_rawpid
        beq @r
@n:     dex
        bpl @l
        lda #0
        sta t_raw
@r:     rts

; tty_rw: one pass of a read (sb4 = 0) or write (sb4 = 1). A = 1 when the
; call is done, 0 when it must wait.
tty_rw: lda sb4
        bne @wr
        jsr raw_alive
        jsr tty_rd
        jmp @k
@wr:    jsr tty_wr
@k:     pha
        lda tx_head         ; something to send: transmit interrupt on
        cmp tx_tail
        beq @r
        lda hold_cnt
        bne @r              ; (tty_tick does it when the hold ends)
        lda #CMD_SEND
        sta ACIA_CMD
@r:     pla
        rts

; ---- reading ----
tty_rd: lda t_raw
        beq @cooked
@raw:   jsr rx_get
        bcs @wait
        jsr in_map
        bcs @raw
        ldy #0
        sta (r0),y
        lda #1
        sta r1
        lda #0
        sta r1+1
        lda #1
        rts
@wait:  lda #0
        rts
@cooked:
        lda lb_ready
        bne @copy
@more:  jsr tx_room         ; the echo needs room
        bcc @wait
        jsr rx_get
        bcs @wait
        jsr in_map
        bcs @more
        cmp #K_RET
        beq @ret
        cmp #K_DEL
        beq @del
        cmp #$15            ; CTRL-U: drop the line
        beq @kill
        cmp #$04            ; CTRL-D on an empty line: end of file
        beq @eof
        cmp #$20
        bcc @more
        cmp #$7f
        bcs @more
        ldx lb_len
        cpx #LBMAX
        bcs @more
        sta lbuf,x
        inc lb_len
        jsr out_byte        ; echo
        jmp @more
@del:   lda lb_len
        beq @more
        dec lb_len
        lda #K_DEL          ; out_byte erases with "\b \b"
        jsr out_byte
        jmp @more
@kill:  lda #0
        sta lb_len
        lda #10
        jsr out_byte
        jmp @more
@eof:   lda lb_len
        bne @more
        sta r1
        sta r1+1
        lda #1
        rts
@ret:   lda #10
        ldx lb_len
        sta lbuf,x
        inc lb_len
        jsr out_byte
        lda #1
        sta lb_ready
@copy:  ldy #0              ; copy min(r1, what is left of the line)
        ldx lb_rpos
@cl:    cpx lb_len
        bcs @done
        lda r1+1
        bne @mv
        cpy r1
        bcs @done
@mv:    lda lbuf,x
        sta (r0),y
        inx
        iny
        bne @cl
@done:  stx lb_rpos
        sty r1
        lda #0
        sta r1+1
        cpx lb_len
        bcc @ok
        sta lb_len
        sta lb_rpos
        sta lb_ready
@ok:    lda #1
        rts

; rx_get: A = next byte typed; carry set if there is none
rx_get: ldx rx_tail
        cpx rx_head
        beq @e
        lda rx_buf,x
        pha
        inx
        txa
        and #RMASK
        sta rx_tail
        pla
        clc
        rts
@e:     sec
        rts

; in_map: A = byte from the line -> A = key as the console gives it
; (RETURN K_RET, DEL K_DEL, ESC [ A-D cursor keys); carry set: drop it
in_map: ldx i_esc
        bne @esc
        cmp #10
        beq @lf
        ldx #0
        stx i_cr
        cmp #13
        beq @cr
        cmp #$1b
        beq @e1
        cmp #$7f
        bne @k
        lda #K_DEL
@k:     cmp #$80            ; carry set (drop) for bytes $80 and up
        rts
@cr:    inc i_cr
        lda #K_RET
        clc
        rts
@lf:    lda i_cr            ; LF after CR: the same RETURN
        ldx #0
        stx i_cr
        cmp #1
        lda #K_RET
        rts
@e1:    lda #1
        sta i_esc
        sec
        rts
@esc:   cpx #1
        bne @e2
        ldx #0
        stx i_esc
        cmp #'['
        bne @drop           ; ESC and anything else: dropped
        lda #2
        sta i_esc
        sec
        rts
@e2:    cmp #$40
        bcc @drop           ; a parameter byte: the sequence goes on
        ldx #0
        stx i_esc
        ldx #3
@m:     cmp esc_in,x
        beq @hit
        dex
        bpl @m
@drop:  sec
        rts
@hit:   lda esc_out,x
        clc
        rts

; ---- writing ----
tty_wr: lda sb5
        bne @go
        inc sb5             ; first pass: s0 = where, s1 = how many
        lda r0
        sta s0
        lda r0+1
        sta s0+1
        lda r1
        sta s1
        lda r1+1
        sta s1+1
@go:    lda s1
        ora s1+1
        beq @done
        jsr tx_room
        bcc @full
        ldy #0
        lda (s0),y
        jsr out_byte
        inc s0
        bne @c
        inc s0+1
@c:     lda s1
        bne @d
        dec s1+1
@d:     dec s1
        jmp @go
@done:  lda #1              ; r1 is still the count asked for
        rts
@full:  lda #0
        rts

; tx_room: carry set if the send ring has room for one translated byte
tx_room:
        lda tx_tail
        clc
        sbc tx_head         ; tail - head - 1
        and #RMASK
        cmp #TXNEED
        rts

; out_byte: A = byte from a program -> the send ring, translated for an
; ANSI (VT100) terminal:
;   LF                 CR LF
;   8 (backspace)      BS space BS: erases
;   12 (form feed)     ESC [ H  ESC [ 2 J: home, clear the screen
;   ESC = row col      ESC [ row+1 ; col+1 H: cursor position
;   ESC R / r / K      ESC [ 7 m / ESC [ m / ESC [ K
;   ESC C fg bg bd     dropped (colours)
out_byte:
        ldx o_esc
        bne @esc
        cmp #$1b
        beq @e
        cmp #10
        beq @lf
        cmp #8
        beq @bs
        cmp #12
        beq @ff
        jmp tx_put
@e:     lda #1
        sta o_esc
        rts
@lf:    lda #13
        jsr tx_put
        lda #10
        jmp tx_put
@bs:    ldx #s_bs - strs
        jmp put_str
@ff:    ldx #s_ff - strs
        jmp put_str
@esc:   cpx #2
        beq @row
        cpx #3
        beq @col
        cpx #1
        bne @skip
        ldx #0
        stx o_esc
        ldx #s_rev - strs
        cmp #'R'
        beq put_str
        ldx #s_norm - strs
        cmp #'r'
        beq put_str
        ldx #s_eol - strs
        cmp #'K'
        beq put_str
        ldx #2              ; ESC = row col
        cmp #'='
        beq @st
        ldx #4              ; ESC C fg bg border: drop 3 more
        cmp #'C'
        bne @r
@st:    stx o_esc
@r:     rts
@skip:  inx                 ; 4, 5, 6: colour bytes
        cpx #7
        bne @st
        ldx #0
        beq @st
@row:   sec
        sbc #32
        cmp #25             ; as the console: clamp to the screen
        bcc @rok
        lda #24
@rok:   sta o_row
        ldx #3
        bne @st
@col:   ldx #0
        stx o_esc
        sec
        sbc #32
        cmp #40
        bcc @cok
        lda #39
@cok:   pha
        ldx #s_csi - strs
        jsr put_str
        lda o_row
        jsr put_dec1
        lda #';'
        jsr tx_put
        pla
        jsr put_dec1
        lda #'H'
        jmp tx_put

; put_dec1: A = 0-39 -> its value + 1 in decimal -> the send ring
put_dec1:
        clc
        adc #1
        ldy #0
@t:     cmp #10
        bcc @u
        sbc #10
        iny
        bne @t
@u:     pha
        tya
        beq @nt
        ora #'0'
        jsr tx_put
@nt:    pla
        ora #'0'
        jmp tx_put

; put_str: X = offset in strs of a NUL-terminated string -> the send ring
put_str:
        lda strs,x
        beq @r
        jsr tx_put
        inx
        bne put_str
@r:     rts

; tx_put: A -> the send ring (room checked by the caller). Keeps X, Y.
tx_put: stx t_px
        ldx tx_head
        sta tx_buf,x
        inx
        txa
        and #RMASK
        sta tx_head
        ldx t_px
        rts

strs:
s_bs:   .byte 8, ' ', 8, 0
s_ff:   .byte $1b, "[H", $1b, "[2J", 0
s_rev:  .byte $1b, "[7m", 0
s_norm: .byte $1b, "[m", 0
s_eol:  .byte $1b, "[K", 0
s_csi:  .byte $1b, "[", 0
esc_in:  .byte "ABCD"
esc_out: .byte K_UP, K_DOWN, K_RIGHT, K_LEFT
