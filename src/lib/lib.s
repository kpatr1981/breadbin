; Breadbin user library: strings, numbers, output, errors
;
; The code lives in the kernel (src/kernel/ulib.s) and is reached through
; the jump table: this module only gives the entries their names, so
; programs `.import print` as before and pay nothing for them. The buffered
; reader (getc) is in getc.s: it needs a buffer of its own in each program.
.include "../../include/breadbin.inc"

lp1  = $30
lp2  = $32
lp3  = $34
lval = $3a              ; 2 bytes
.exportzp lp1, lp2, lp3, lval

print       = SYS_PRINT
eprint      = SYS_EPRINT
fprint      = SYS_FPRINT
putc        = SYS_PUTC
eputc       = SYS_EPUTC
fputc       = SYS_FPUTC
newline     = SYS_NEWLINE
print_dec   = SYS_PRINTDEC
print_dec_w = SYS_PRINTDECW
print_hex   = SYS_PRINTHEX
dec_str     = SYS_DECSTR
parse_dec   = SYS_PARSEDEC
strlen      = SYS_STRLEN
strcmp      = SYS_STRCMP
argn        = SYS_ARGN
perr        = SYS_PERR
errstr      = SYS_ERRSTR
open_or_die = SYS_OPENDIE
basename    = SYS_BASENAME
exit        = SYS_EXIT
write_buf   = SYS_WRITE         ; A = fd, r0/r1 set

.export print, eprint, fprint, putc, eputc, newline, print_dec, print_dec_w
.export strlen, parse_dec, strcmp, argn, perr, errstr, exit, write_buf
.export fputc, print_hex, open_or_die, basename, dec_str
