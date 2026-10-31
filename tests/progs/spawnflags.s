; spawnflags: spawn "sleep 99" with every flag bit set in Y; prints its pid
; and exits without waiting (the kernel must ignore the unknown bits)
.include "../../include/breadbin.inc"
.import print_dec, newline
.segment "CODE"
        lda #<s_sleep
        sta r0
        lda #>s_sleep
        sta r0+1
        lda #<av
        sta r1
        lda #>av
        sta r1+1
        lda #0
        ldx #1
        ldy #$ff & ~SP_IGNINT
        jsr SYS_SPAWN
        ldx #0
        jsr print_dec
        jsr newline
        lda #0
        jmp SYS_EXIT
.segment "RODATA"
s_sleep: .byte "/bin/sleep", 0
s_99:    .byte "99", 0
.segment "DATA"
av:     .word s_sleep, s_99, 0
