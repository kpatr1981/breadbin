; bigarg: spawn echo with one 255-character argument (256 bytes with its
; NUL), which must fail with E2BIG (the kernel once counted it as 0 bytes
; and let it overrun the child's memory), then with a 254-character one,
; which must work. Prints ok or bad.
.include "../../include/breadbin.inc"
.import print
nullfd = $23
.segment "CODE"
        lda #<devnull
        sta r0
        lda #>devnull
        sta r0+1
        lda #O_WRONLY
        jsr SYS_OPEN
        bcs bad
        sta nullfd
        ldx #0
        lda #'x'
@f:     sta arg,x
        inx
        cpx #255
        bne @f
        lda #0
        sta arg+255
        jsr spawn               ; 255 characters
        bcc bad
        cmp #E2BIG
        bne bad
        lda #0
        sta arg+254
        jsr spawn               ; 254 characters
        bcs bad
        ldx #0
        jsr SYS_WAIT
        lda #<s_ok
        ldx #>s_ok
        jmp print
bad:    lda #<s_bad
        ldx #>s_bad
        jmp print
spawn:  lda #<path
        sta r0
        lda #>path
        sta r0+1
        lda #<av
        sta r1
        lda #>av
        sta r1+1
        lda #0
        ldx nullfd
        ldy #0
        jmp SYS_SPAWN
.segment "RODATA"
path:    .byte "/bin/echo", 0
devnull: .byte "/dev/null", 0
a0:      .byte "echo", 0
s_ok:    .byte "ok", 10, 0
s_bad:   .byte "bad", 10, 0
.segment "DATA"
av:      .word a0, arg, 0
.segment "BSS"
arg:     .res 256
