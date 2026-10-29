; whoami: print the user name for the current uid (from /etc/passwd)
.include "../../include/c64os.inc"
.import print, newline, print_dec, pw_find_uid, pw_name
.segment "CODE"
        jsr SYS_GETUID
        sta uid
        jsr pw_find_uid
        bcs @num
        lda #<pw_name
        ldx #>pw_name
        jsr print
        jmp newline
@num:   lda uid
        ldx #0
        jsr print_dec
        jmp newline
.segment "BSS"
uid: .res 1
