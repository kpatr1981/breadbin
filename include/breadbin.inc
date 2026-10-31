; Breadbin system interface for programs (ca65)
;
; Call a syscall with `jsr SYS_name`. Arguments in A, X, Y and r0..r2.
; Return: carry clear = ok; carry set = error, A = errno.

SYS_BASE   = $CF00

SYS_EXIT     = SYS_BASE + 3*0
SYS_SPAWN    = SYS_BASE + 3*1
SYS_WAIT     = SYS_BASE + 3*2
SYS_KILL     = SYS_BASE + 3*3
SYS_GETPID   = SYS_BASE + 3*4
SYS_YIELD    = SYS_BASE + 3*5
SYS_SLEEP    = SYS_BASE + 3*6
SYS_OPEN     = SYS_BASE + 3*7
SYS_CLOSE    = SYS_BASE + 3*8
SYS_READ     = SYS_BASE + 3*9
SYS_WRITE    = SYS_BASE + 3*10
SYS_PIPE     = SYS_BASE + 3*11
SYS_MKDIR    = SYS_BASE + 3*12
SYS_RMDIR    = SYS_BASE + 3*13
SYS_UNLINK   = SYS_BASE + 3*14
SYS_RENAME   = SYS_BASE + 3*15
SYS_CHDIR    = SYS_BASE + 3*16
SYS_GETCWD   = SYS_BASE + 3*17
SYS_STAT     = SYS_BASE + 3*18
SYS_PROCINFO = SYS_BASE + 3*19
SYS_MEMINFO  = SYS_BASE + 3*20
SYS_FSINFO   = SYS_BASE + 3*21
SYS_TIME     = SYS_BASE + 3*22
SYS_ISATTY   = SYS_BASE + 3*23
SYS_CONMODE  = SYS_BASE + 3*24
SYS_GETUID   = SYS_BASE + 3*25
SYS_SETUID   = SYS_BASE + 3*26
SYS_MOUNT    = SYS_BASE + 3*27
SYS_UMOUNT   = SYS_BASE + 3*28
SYS_MNTINFO  = SYS_BASE + 3*29
SYS_DISKIO   = SYS_BASE + 3*30
SYS_FG       = SYS_BASE + 3*31
SYS_SYNC     = SYS_BASE + 3*32

; The user library is in the jump table too. These entries are not system
; calls: they run as part of your program (using zero page $30-$3F) and
; call the system calls above. src/lib/lib.s gives them their short names.
SYS_PRINT    = SYS_BASE + 3*33  ; A/X = string -> stdout
SYS_EPRINT   = SYS_BASE + 3*34  ; A/X = string -> stderr
SYS_FPRINT   = SYS_BASE + 3*35  ; A/X = string, Y = fd
SYS_PUTC     = SYS_BASE + 3*36  ; A = byte -> stdout
SYS_EPUTC    = SYS_BASE + 3*37  ; A = byte -> stderr
SYS_FPUTC    = SYS_BASE + 3*38  ; A = byte, Y = fd
SYS_NEWLINE  = SYS_BASE + 3*39  ; a 10 to stdout
SYS_PRINTDEC = SYS_BASE + 3*40  ; A/X = number, decimal to stdout
SYS_PRINTDECW= SYS_BASE + 3*41  ; A/X = number, Y = width (right aligned)
SYS_PRINTHEX = SYS_BASE + 3*42  ; A -> two hex digits to stdout
SYS_DECSTR   = SYS_BASE + 3*43  ; A/X = number -> A/X = digits (at $3a), Y = length
SYS_PARSEDEC = SYS_BASE + 3*44  ; A/X = string -> A/X = value; carry set if not a number
SYS_STRLEN   = SYS_BASE + 3*45  ; A/X = string -> A = Y = length
SYS_STRCMP   = SYS_BASE + 3*46  ; strings at $30 and $32 -> Z set if equal
SYS_ARGN     = SYS_BASE + 3*47  ; A = index -> A/X = argv[index]; carry set if none
SYS_PERR     = SYS_BASE + 3*48  ; A = errno, X/Y = extra string or 0/0 -> "prog: extra: message" to stderr
SYS_ERRSTR   = SYS_BASE + 3*49  ; A = errno -> A/X = message
SYS_OPENDIE  = SYS_BASE + 3*50  ; A/X = path, Y = flags -> A = fd, or print the error and exit 1
SYS_BASENAME = SYS_BASE + 3*51  ; A/X = path -> A/X = the part after the last '/'

SYS_EXEC     = SYS_BASE + 3*52  ; r0 = path, r1 = argv: this process becomes that program (returns only on error)

; argument registers (zero page, saved per process)
r0 = $02
r1 = $04
r2 = $06

; program entry state
argv = $20          ; pointer to NULL-terminated array of string pointers
argc = $22
; $23-$2F free for programs, $30-$3F used by lib.s

; open flags
O_RDONLY = $00
O_WRONLY = $01
O_RDWR   = $02
O_CREAT  = $10
O_TRUNC  = $20
O_APPEND = $40

; spawn flags (Y)
SP_BG     = $01
SP_IGNINT = $02
SP_JOB    = $04      ; job control: r2 = job (process group) to join, 0 = a new one
SP_ERR    = $08      ; stderr is fd r2+1 (default: the caller's fd 2)

; wait flags (X)
W_NOHANG   = $01
W_UNTRACED = $02     ; also report children that stopped (X = WSTOPPED)
W_JOB      = $04     ; A is a job (process group): wait for any of its processes
WSTOPPED   = $80 | 20

; stat buffer: type, nlink, size(3), ino, dev, 0
T_FILE = 1
T_DIR  = 2
T_CHR  = 3

; errno
EPERM   = 1
E2BIG   = 7
ENOENT  = 2
ESRCH   = 3
EIO     = 5
ENOEXEC = 8
EBADF   = 9
ECHILD  = 10
EAGAIN  = 11
ENOMEM  = 12
EBUSY   = 16
EEXIST  = 17
EXDEV   = 18
ENODEV  = 19
ENOTDIR = 20
EISDIR  = 21
EINVAL  = 22
EMFILE  = 24
EFBIG   = 27
ENOSPC  = 28
EPIPE   = 32
ENAMETOOLONG = 36
ENOTEMPTY = 39

; console: raw-mode key codes and output escapes
K_UP    = $10
K_DOWN  = $0e
K_LEFT  = $02
K_RIGHT = $06
K_HOME  = $01
K_CLR   = $0c
K_DEL   = $08
K_RET   = $0a
K_F1    = $85
K_F3    = $86
K_F5    = $87
K_F7    = $88
ESC     = $1b           ; ESC = row+32 col+32, ESC R/r reverse, ESC K clear eol,
                        ; ESC C fg+32 bg+32 border+32 colours

; signals
SIGHUP  = 1
SIGINT  = 2
SIGKILL = 9
SIGPIPE = 13
SIGTERM = 15
SIGCONT = 18
SIGSTOP = 19
SIGTSTP = 20
