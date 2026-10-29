; init: first process. Shows /etc/motd, runs the shell, reaps orphans.
.include "../../include/c64os.inc"
.import print, eprint, perr, write_buf

.segment "CODE"
start:
        jsr motd
@spawn: lda #<sh_path
        sta r0
        lda #>sh_path
        sta r0+1
        lda #<sh_argv
        sta r1
        lda #>sh_argv
        sta r1+1
        lda #0
        ldx #1
        ldy #SP_IGNINT
        jsr SYS_SPAWN
        bcc @ok
        ldx #<sh_path
        ldy #>sh_path
        jsr perr
        lda #<250
        ldx #>250
        jsr SYS_SLEEP
        jmp @spawn
@ok:    sta shpid
@wait:  lda #$ff
        ldx #0
        jsr SYS_WAIT
        bcs @spawn
        cmp shpid
        bne @wait
        jmp @spawn

motd:   lda #<motd_path
        sta r0
        lda #>motd_path
        sta r0+1
        lda #O_RDONLY
        jsr SYS_OPEN
        bcs @r
        sta fd
@l:     lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        lda #<128
        sta r1
        lda #0
        sta r1+1
        lda fd
        jsr SYS_READ
        bcs @c
        lda r1
        beq @c
        lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        lda #1
        jsr write_buf
        jmp @l
@c:     lda fd
        jsr SYS_CLOSE
@r:     rts

.segment "RODATA"
sh_path:   .byte "/bin/sh", 0
sh_arg0:   .byte "sh", 0
sh_argv:   .word sh_arg0, 0
motd_path: .byte "/etc/motd", 0

.segment "BSS"
shpid: .res 1
fd:    .res 1
buf:   .res 128
