; init: first process. Shows /etc/motd, runs the shell, reaps orphans.
.include "../../include/breadbin.inc"
.import print, eprint, perr, write_buf

.segment "CODE"
start:
        lda #<theme_path    ; apply the saved colour theme
        sta r0
        lda #>theme_path
        sta r0+1
        lda #<theme_argv
        sta r1
        lda #>theme_argv
        sta r1+1
        lda #0
        ldx #1
        ldy #SP_IGNINT
        jsr SYS_SPAWN
        bcs @nt
        ldx #0
        jsr SYS_WAIT
@nt:    jsr motd
        ; with /etc/passwd, users log in; otherwise the shell runs directly
        lda #<pw_path
        sta r0
        lda #>pw_path
        sta r0+1
        lda #<st
        sta r1
        lda #>st
        sta r1+1
        jsr SYS_STAT
        bcs @spawn
        lda #<login_path
        sta sh_ptr
        lda #>login_path
        sta sh_ptr+1
        lda #<login_argv
        sta sh_av
        lda #>login_argv
        sta sh_av+1
@spawn: lda sh_ptr
        sta r0
        lda sh_ptr+1
        sta r0+1
        lda sh_av
        sta r1
        lda sh_av+1
        sta r1+1
        lda #0
        ldx #1
        ldy #SP_IGNINT
        jsr SYS_SPAWN
        bcc @ok
        ldx sh_ptr
        ldy sh_ptr+1
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

.segment "DATA"
sh_ptr:    .word sh_path
sh_av:     .word sh_argv
.segment "RODATA"
theme_path: .byte "/bin/theme", 0
theme_arg0: .byte "theme", 0
theme_argv: .word theme_arg0, 0
login_path: .byte "/bin/login", 0
login_arg0: .byte "login", 0
login_argv: .word login_arg0, 0
pw_path:   .byte "/etc/passwd", 0
sh_path:   .byte "/bin/sh", 0
sh_arg0:   .byte "sh", 0
sh_argv:   .word sh_arg0, 0
motd_path: .byte "/etc/motd", 0

.segment "BSS"
shpid: .res 1
st:    .res 8
fd:    .res 1
buf:   .res 128
