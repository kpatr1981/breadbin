; ps: list processes (any arguments, like `ps aux`, are accepted and ignored)
.include "../../include/breadbin.inc"
.import print, putc, newline, print_dec_w, pw_find_uid, pw_name
slot = $23
.segment "CODE"
        lda #$ff
        sta last_uid
        lda #<hdr
        ldx #>hdr
        jsr print
        lda #0
        sta slot
@l:     lda #<buf
        sta r0
        lda #>buf
        sta r0+1
        lda slot
        jsr SYS_PROCINFO
        bcs @n
        lda buf
        ldx #0
        ldy #4
        jsr print_dec_w
        lda buf+1
        ldx #0
        ldy #5
        jsr print_dec_w
        lda #' '
        jsr putc
        jsr user
        ldx buf+2
        lda states,x
        jsr putc
        lda buf+3
        and #SP_BG
        beq @fg
        lda #'&'
        bne @f
@fg:    lda #' '
@f:     jsr putc
        lda buf+4
        ldx #0
        ldy #4
        jsr print_dec_w
        lda #' '
        jsr putc
        lda #<(buf+5)
        ldx #>(buf+5)
        jsr print
        jsr newline
@n:     inc slot
        lda slot
        cmp #16
        bne @l
        rts

; user: the name for uid buf+16 (or its number), padded to 7 columns
col = $24
user:   lda buf+16
        cmp last_uid
        beq @have
        sta last_uid
        jsr pw_find_uid
        lda #1
        bcc @ok
        lda #0              ; not in /etc/passwd: show the number
@ok:    sta found
@have:  lda found
        beq @num
        lda #0
        sta col
@c:     ldx col
        lda pw_name,x
        beq @pad
        jsr putc
        inc col
        lda col
        cmp #6
        bne @c
@pad:   lda #' '
        jsr putc
        inc col
        lda col
        cmp #7
        bcc @pad
        rts
@num:   lda last_uid
        ldx #0
        ldy #6
        jsr print_dec_w
        lda #' '
        jmp putc

.segment "RODATA"
hdr:    .byte " pid ppid user   st  mem name", 10, 0
states: .byte "?rszT"
.segment "BSS"
buf: .res 17
last_uid: .res 1
found: .res 1
