; pipeleak: fill the fd table, call pipe() 4 times (each must fail), close
; the extra fds; then pipe() must work again. Prints "ok" or "leak".
.include "../../include/breadbin.inc"
.import print
n = $23
.segment "CODE"
        lda #0
        sta n
@o:     lda #<s_null
        sta r0
        lda #>s_null
        sta r0+1
        lda #O_RDONLY
        jsr SYS_OPEN
        bcs @full
        ldx n
        sta fds,x
        inc n
        bne @o
@full:  ldx #4
@p:     txa
        pha
        jsr SYS_PIPE
        pla
        tax
        dex
        bne @p
@c:     ldx n
        beq @try
        dec n
        lda fds-1,x
        jsr SYS_CLOSE
        jmp @c
@try:   jsr SYS_PIPE
        bcs @leak
        lda #<s_ok
        ldx #>s_ok
        jsr print
        lda #0
        jmp SYS_EXIT
@leak:  lda #<s_leak
        ldx #>s_leak
        jsr print
        lda #1
        jmp SYS_EXIT
.segment "RODATA"
s_null: .byte "/dev/null", 0
s_ok:   .byte "ok", 10, 0
s_leak: .byte "leak", 10, 0
.segment "BSS"
fds:    .res 8
