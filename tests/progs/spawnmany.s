; spawnmany count pid: run /bin/echo count times; "dup" if a child gets
; the pid of a live process (or pid 0/1), else "ok"
.include "../../include/breadbin.inc"
.import argn, parse_dec, perr, print
n    = $23
live = $25
nul  = $26
.segment "CODE"
        lda #1
        jsr argn
        jsr parse_dec
        sta n
        stx n+1
        lda #2
        jsr argn
        jsr parse_dec
        sta live
        lda #<s_null
        sta r0
        lda #>s_null
        sta r0+1
        lda #O_WRONLY
        jsr SYS_OPEN
        bcs @err
        sta nul
@l:     lda n
        ora n+1
        beq @ok
        lda #<s_echo
        sta r0
        lda #>s_echo
        sta r0+1
        lda #0
        sta r1
        sta r1+1
        ldx nul
        ldy #0
        jsr SYS_SPAWN       ; stdin 0, stdout /dev/null
        bcs @err
        cmp live
        beq @dup
        cmp #2
        bcc @dup
        ldx #0
        jsr SYS_WAIT
        lda n
        bne @d
        dec n+1
@d:     dec n
        jmp @l
@ok:    lda #<s_ok
        ldx #>s_ok
        jsr print
        lda #0
        jmp SYS_EXIT
@dup:   lda #<s_dup
        ldx #>s_dup
        jsr print
        lda #1
        jmp SYS_EXIT
@err:   ldx #0
        ldy #0
        jsr perr
        lda #1
        jmp SYS_EXIT
.segment "RODATA"
s_null: .byte "/dev/null", 0
s_echo: .byte "/bin/echo", 0
s_ok:   .byte "ok", 10, 0
s_dup:  .byte "dup", 10, 0
