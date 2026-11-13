; seek file: SYS_SEEK checks, one result per line:
;   the 3 bytes at offset 5; the position 4 bytes before the end and the
;   3 bytes there; past the end (EINVAL); on the console (EINVAL)
.include "../../include/breadbin.inc"
.import argn, open_or_die, print, print_dec, newline, perr
fd   = $23
.segment "CODE"
        lda #1
        jsr argn
        ldy #O_RDONLY
        jsr open_or_die
        sta fd
        ; from the start: offset 5
        lda #5
        ldx #0
        ldy #SEEK_SET
        jsr seek
        bcs @fail
        jsr show3
        ; from the end: 4 back
        lda #4
        ldx #0
        ldy #SEEK_END
        jsr seek
        bcs @fail
        lda r0
        ldx r0+1
        jsr print_dec
        jsr newline
        jsr show3
        ; past the end
        lda #$ff
        ldx #$ff
        ldy #SEEK_SET
        jsr seek
        jsr result
        ; the console
        lda #0
        sta fd
        ldx #0
        ldy #SEEK_SET
        jsr seek
        jsr result
        lda #0
        jmp SYS_EXIT
@fail:  ldx #0
        ldy #0
        jsr perr
        lda #1
        jmp SYS_EXIT

; seek: A/X = offset (16 bits), Y = whence, on fd
seek:   sta r0
        stx r0+1
        lda #0
        sta r1
        lda fd
        jmp SYS_SEEK

; result: "ok" or "einval" (or "error") for the last seek
result: bcc @ok
        cmp #EINVAL
        bne @e
        lda #<s_inval
        ldx #>s_inval
        bne @p
@e:     lda #<s_err
        ldx #>s_err
        bne @p
@ok:    lda #<s_ok
        ldx #>s_ok
@p:     jsr print
        jmp newline

; show3: read and print the next 3 bytes
show3:  lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        lda #3
        sta r1
        lda #0
        sta r1+1
        sta buf+3
        lda fd
        jsr SYS_READ
        lda #<buf
        ldx #>buf
        jsr print
        jmp newline

.segment "RODATA"
s_ok:    .byte "ok", 0
s_inval: .byte "einval", 0
s_err:   .byte "error", 0
.segment "BSS"
buf:     .res 4
