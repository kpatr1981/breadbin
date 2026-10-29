; /etc/passwd access. Lines: name:hash:uid:home
;   hash is 4 hex digits of pw_hash(password), or empty for no password
.include "../../include/c64os.inc"
.importzp lp1
.import set_input, getc, parse_dec
.export pw_open, pw_next, pw_find_uid, pw_find_name, pw_hash
.export pw_name, pw_hashs, pw_uid, pw_home, pw_line, pw_len
.segment "BSS"
pw_line:  .res 96
pw_len:   .res 1
pw_name:  .res 16
pw_hashs: .res 8
pw_uid:   .res 1
pw_home:  .res 48
pw_fd:    .res 1
pw_want:  .res 16
pw_h:     .res 2
field:    .res 8
.segment "CODE"
; pw_open -> carry set if /etc/passwd is missing
pw_open:
        lda #<path
        sta r0
        lda #>path
        sta r0+1
        lda #O_RDONLY
        jsr SYS_OPEN
        bcs @r
        sta pw_fd
        jsr set_input
        clc
@r:     rts
pw_close:
        lda pw_fd
        jmp SYS_CLOSE

; pw_next: read and split the next line -> carry set at EOF
pw_next:
        ldx #0
@c:     stx pw_len
        jsr getc
        ldx pw_len
        bcs @eof
        cmp #10
        beq @e
        cpx #95
        bcs @c
        sta pw_line,x
        inx
        bne @c
@eof:   cpx #0
        bne @e
        sec
        rts
@e:     lda #0
        sta pw_line,x
        ldx #0              ; line index
        ldy #0
        jsr fld
        lda #0
        sta pw_name,y
        ldy #0
@h:     lda pw_line,x
        beq @hd
        inx
        cmp #':'
        beq @hd
        cpy #7
        bcs @h
        sta pw_hashs,y
        iny
        bne @h
@hd:    lda #0
        sta pw_hashs,y
        ldy #0
@u:     lda pw_line,x
        beq @ud
        inx
        cmp #':'
        beq @ud
        sta field,y
        iny
        cpy #7
        bcc @u
@ud:    lda #0
        sta field,y
        stx pw_len
        lda #<field
        ldx #>field
        jsr parse_dec
        sta pw_uid
        ldx pw_len
        ldy #0
@hm:    lda pw_line,x
        sta pw_home,y
        beq @done
        inx
        iny
        cpy #47
        bcc @hm
        lda #0
        sta pw_home,y
@done:  lda pw_home
        bne @ok
        lda #'/'
        sta pw_home
        lda #0
        sta pw_home+1
@ok:    clc
        rts
fld:    lda pw_line,x
        beq @r
        inx
        cmp #':'
        beq @r
        cpy #15
        bcs fld
        sta pw_name,y
        iny
        bne fld
@r:     rts

; pw_find_uid: A = uid -> fields of that user; carry set if none
pw_find_uid:
        sta pw_want
        jsr pw_open
        bcs @r
@l:     jsr pw_next
        bcs @no
        lda pw_uid
        cmp pw_want
        bne @l
        jsr pw_close
        clc
        rts
@no:    jsr pw_close
        sec
@r:     rts

; pw_find_name: A/X = name -> fields; carry set if none
pw_find_name:
        sta lp1
        stx lp1+1
        ldy #0
@c:     lda (lp1),y
        sta pw_want,y
        beq @o
        iny
        cpy #15
        bcc @c
        lda #0
        sta pw_want,y
@o:     jsr pw_open
        bcs @r
@l:     jsr pw_next
        bcs @no
        ldy #0
@m:     lda pw_name,y
        cmp pw_want,y
        bne @l
        cmp #0
        beq @f
        iny
        bne @m
@f:     jsr pw_close
        clc
        rts
@no:    jsr pw_close
        sec
@r:     rts

; pw_hash: A/X = password -> pw_h (16-bit, not cryptographic) and
; pw_hashs-style 4 hex digits in field
pw_hash:
        sta lp1
        stx lp1+1
        lda #$a5
        sta pw_h
        lda #$c3
        sta pw_h+1
        ldy #0
@l:     lda (lp1),y
        beq @d
        eor pw_h
        sta pw_h
        ; rotate left 3 and mix
        ldx #3
@r3:    asl pw_h
        rol pw_h+1
        bcc @nc
        inc pw_h
@nc:    dex
        bne @r3
        lda pw_h+1
        eor #$5b
        sta pw_h+1
        iny
        bne @l
@d:     lda pw_h+1
        jsr hx
        sta field
        stx field+1
        lda pw_h
        jsr hx
        sta field+2
        stx field+3
        lda #0
        sta field+4
        lda #<field
        ldx #>field
        rts
hx:     pha
        lsr a
        lsr a
        lsr a
        lsr a
        jsr nib
        tay
        pla
        and #15
        jsr nib
        tax
        tya
        rts
nib:    cmp #10
        bcc @d
        adc #'a'-'0'-11
@d:     adc #'0'
        rts
.segment "RODATA"
path: .byte "/etc/passwd", 0
