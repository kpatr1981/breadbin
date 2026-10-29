; login: ask for a user name (and password), then run that user's shell
.include "../../include/breadbin.inc"
.import print, eprint, newline, putc, pw_find_name, pw_hash
.import pw_hashs, pw_uid, pw_home, pw_name
.importzp lp1
.segment "CODE"
start:
@ask:   lda #<s_login
        ldx #>s_login
        jsr print
        jsr readline
        bcc @got
        lda #0
        jmp SYS_EXIT
@got:   lda line
        beq @ask
        lda #<line
        ldx #>line
        jsr pw_find_name
        bcs @bad
        lda pw_hashs
        beq @ok
        lda #<s_pass
        ldx #>s_pass
        jsr print
        jsr read_secret
        lda #<line
        ldx #>line
        jsr pw_hash         ; A/X = 4 hex digits
        sta lp1
        stx lp1+1
        ldy #0
@c:     lda (lp1),y
        cmp pw_hashs,y
        bne @bad
        iny
        cpy #5
        bcc @c
@ok:    lda pw_uid
        jsr SYS_SETUID
        lda #<pw_home
        sta r0
        lda #>pw_home
        sta r0+1
        jsr SYS_CHDIR
        lda #<sh_path
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
        bcs @bad
        ldx #0
        jsr SYS_WAIT
        lda #0
        jmp SYS_EXIT
@bad:   lda #<s_bad
        ldx #>s_bad
        jsr eprint
        jmp @ask

; readline: cooked console line -> line (no newline); carry set at EOF
readline:
        lda #<line
        sta r0
        lda #>line
        sta r0+1
        lda #31
        sta r1
        lda #0
        sta r1+1
        lda #0
        jsr SYS_READ
        bcs @eof
        ldx r1
        beq @eof
        dex
        lda #0
        sta line,x
        clc
        rts
@eof:   sec
        rts

; read_secret: raw keys until RETURN, echo '*'
read_secret:
        lda #1
        jsr SYS_CONMODE
        ldx #0
@l:     stx n
        lda #<key
        sta r0
        lda #>key
        sta r0+1
        lda #1
        sta r1
        lda #0
        sta r1+1
        lda #0
        jsr SYS_READ
        ldx n
        lda key
        cmp #K_RET
        beq @d
        cmp #K_DEL
        bne @ch
        cpx #0
        beq @l
        dex
        jmp @l
@ch:    cmp #$20
        bcc @l
        cpx #30
        bcs @l
        sta line,x
        inx
        lda #'*'
        jsr putc
        ldx n
        inx
        jmp @l
@d:     lda #0
        sta line,x
        lda #0
        jsr SYS_CONMODE
        jmp newline
.segment "RODATA"
s_login: .byte 10, "breadbin login: ", 0
s_pass:  .byte "password: ", 0
s_bad:   .byte "login incorrect", 10, 0
sh_path: .byte "/bin/sh", 0
sh_arg0: .byte "sh", 0
sh_argv: .word sh_arg0, 0
.segment "BSS"
line: .res 32
key:  .res 1
n:    .res 1
