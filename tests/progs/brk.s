; brk: execute a BRK instruction (the kernel must kill only this process)
.segment "CODE"
        brk
        .byte 0
