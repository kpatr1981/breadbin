; hello.s - a c64os program you can assemble on the c64:
;   as hello.s hello
;   ./hello
start:  ldx #0
loop:   lda msg,x           ; print the message one char at a time
        beq done
        stx save
        sta ch
        lda #<ch
        sta r0
        lda #>ch
        sta r0+1
        lda #1
        sta r1
        lda #0
        sta r1+1
        lda #1              ; fd 1 = stdout
        jsr sys_write
        ldx save
        inx
        bne loop
done:   lda #0
        jmp sys_exit
msg:    .byte "hello, world! (assembled on a c64)", 10, 0
save:   .res 1
ch:     .res 1
