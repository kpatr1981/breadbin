; execfail: exec of a missing program must come back with ENOENT and leave
; this program running; then exec /bin/echo ok, which prints "ok"
.include "../../include/breadbin.inc"
.import print
.segment "CODE"
        lda #<nope
        sta r0
        lda #>nope
        sta r0+1
        lda #0
        sta r1
        sta r1+1
        jsr SYS_EXEC
        bcc bad
        cmp #ENOENT
        bne bad
        lda #<echo
        sta r0
        lda #>echo
        sta r0+1
        lda #<av
        sta r1
        lda #>av
        sta r1+1
        jsr SYS_EXEC
bad:    lda #<s_bad
        ldx #>s_bad
        jmp print
.segment "RODATA"
nope:   .byte "/nope", 0
echo:   .byte "/bin/echo", 0
a0:     .byte "echo", 0
a1:     .byte "ok", 0
s_bad:  .byte "bad", 10, 0
.segment "DATA"
av:     .word a0, a1, 0
