; getc: buffered reading, 256 bytes per system call (the buffer is the one
; part of the user library that lives in the program)
.include "../../include/breadbin.inc"
.export getc, set_input

.segment "BSS"
rd_fd:  .res 1
rd_pos: .res 1
rd_len: .res 1
rd_buf: .res 256

.segment "CODE"
; set_input: A = fd for getc
set_input:
        sta rd_fd
        lda #0
        sta rd_pos
        sta rd_len
        rts

; getc -> A = next byte of the input fd; carry set at EOF
getc:   ldx rd_pos
        cpx rd_len
        bne @have
        lda #<rd_buf
        sta r0
        lda #>rd_buf
        sta r0+1
        lda #0
        sta r1
        lda #1
        sta r1+1
        lda rd_fd
        jsr SYS_READ
        bcs @eof
        lda r1+1
        bne @full
        lda r1
        beq @eof
        sta rd_len
        jmp @z
@full:  lda #0              ; 256 bytes: rd_len 0 means 256
        sta rd_len
@z:     ldx #0
        stx rd_pos
        lda rd_buf,x
        inc rd_pos
        clc
        rts
@have:  lda rd_buf,x
        inc rd_pos
        clc
        rts
@eof:   lda #0
        sta rd_len
        sta rd_pos
        sec
        rts
