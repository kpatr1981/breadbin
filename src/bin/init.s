; init: first process. Shows /etc/motd, runs the shell, reaps orphans.
; With /etc/passwd and a serial card (/dev/ttyS0), it also runs a login on
; the serial line, and starts it again when it exits.
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
        inc have_pw
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
@wait:  jsr tty_up
        lda #$ff
        ldx #0
        jsr SYS_WAIT
        bcs @spawn
        cmp ttypid
        bne @nt2
        lda #0              ; the serial login ended: start another
        sta ttypid
        beq @wait
@nt2:   cmp shpid
        bne @wait
        jmp @spawn

; tty_up: a login on /dev/ttyS0, if there is none running. Only with
; /etc/passwd: the serial line never gets a shell without a password.
tty_up: lda ttypid
        bne @r
        lda have_pw
        beq @r
        lda ttyfd
        bne @have
        lda #<tty_path
        sta r0
        lda #>tty_path
        sta r0+1
        lda #O_RDWR
        jsr SYS_OPEN
        bcc @op
        lda #$ff            ; no card: don't try again
@op:    sta ttyfd
@have:  cmp #$ff
        beq @r
        lda #<login_path
        sta r0
        lda #>login_path
        sta r0+1
        lda #<login_argv
        sta r1
        lda #>login_argv
        sta r1+1
        lda #0
        sta r2
        lda ttyfd
        sta r2+1            ; stderr too (SP_ERR)
        tax
        ldy #SP_IGNINT | SP_ERR
        jsr SYS_SPAWN
        bcs @r
        sta ttypid
@r:     rts

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
tty_path:  .byte "/dev/ttyS0", 0

.segment "BSS"
shpid: .res 1
ttypid: .res 1
ttyfd: .res 1
have_pw: .res 1
st:    .res 16
fd:    .res 1
buf:   .res 128
