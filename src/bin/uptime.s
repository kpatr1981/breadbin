; uptime: time since boot and number of processes
.include "../../include/c64os.inc"
.import print, print_dec, putc, newline, print_dec_w
.segment "CODE"
        jsr SYS_TIME            ; A/X/Y = jiffies (60 per second)
        sta t
        stx t+1
        sty t+2
        ; seconds = jiffies / 60 (24-bit / 8-bit)
        lda #60
        jsr div24
        ; t = seconds; h = t/3600 via /60 /60
        lda #60
        jsr div24
        lda rem
        sta secs
        lda #60
        jsr div24
        lda rem
        sta mins
        lda #<s_up
        ldx #>s_up
        jsr print
        lda t
        ldx t+1
        jsr print_dec
        lda #':'
        jsr putc
        lda mins
        jsr two
        lda #':'
        jsr putc
        lda secs
        jsr two
        lda #<s_procs
        ldx #>s_procs
        jsr print
        lda #<mi
        sta r0
        lda #>mi
        sta r0+1
        jsr SYS_MEMINFO
        lda mi+3
        ldx #0
        jsr print_dec
        lda #<s_p2
        ldx #>s_p2
        jmp print
two:    cmp #10
        bcs @t
        pha
        lda #'0'
        jsr putc
        pla
@t:     ldx #0
        jmp print_dec
; div24: t /= A, rem = t % A
div24:  sta dv
        lda #0
        ldx #24
@l:     asl t
        rol t+1
        rol t+2
        rol a
        bcs @s
        cmp dv
        bcc @n
@s:     sbc dv
        inc t
@n:     dex
        bne @l
        sta rem
        rts
.segment "RODATA"
s_up:    .byte "up ", 0
s_procs: .byte ", ", 0
s_p2:    .byte " processes", 10, 0
.segment "BSS"
t:    .res 3
dv:   .res 1
rem:  .res 1
secs: .res 1
mins: .res 1
mi:   .res 8
