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

; wait flags (X)
W_NOHANG = $01

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
SIGINT  = 2
SIGKILL = 9
SIGPIPE = 13
SIGTERM = 15
