; c64os kernel: boot stub, init, panic
.include "k.inc"

.import __CODE_LOAD__, __CODE_RUN__, __CODE_SIZE__, __RODATA_SIZE__, __DATA_SIZE__
.import __JUMPTAB_LOAD__, __JUMPTAB_RUN__, __BSS_RUN__, __BSS_SIZE__

.segment "ZEROPAGE"
cur:          .res 1    ; current process slot, $FF = none
in_kernel:    .res 1    ; nonzero while executing kernel code
need_resched: .res 1
slice:        .res 1
ticks:        .res 3    ; jiffies since boot
p1:           .res 2    ; kernel pointers (not preserved across blocking)
p2:           .res 2
p3:           .res 2
p4:           .res 2
k_a:          .res 1
k_x:          .res 1
k_n:          .res 1
k_vec:        .res 2
tmp0:         .res 1
tmp1:         .res 1
tmp2:         .res 1
tmp3:         .res 1
stop_prev:    .res 1
intr_pending: .res 1

; ---------------------------------------------------------------------
.segment "LOADADDR"
        .word $0801

.segment "STUB"
        ; 10 SYS2061
        .word basic_end, 10
        .byte $9e, "2061", 0
basic_end:
        .word 0
stub:
        sei
        cld
        ; copy CODE+RODATA+DATA to its run address
        lda #<__CODE_LOAD__
        sta $fb
        lda #>__CODE_LOAD__
        sta $fc
        lda #<__CODE_RUN__
        sta $fd
        lda #>__CODE_RUN__
        sta $fe
        ldx #>(__CODE_SIZE__ + __RODATA_SIZE__ + __DATA_SIZE__ + 255)
        jsr stub_copy
        lda #<__JUMPTAB_LOAD__
        sta $fb
        lda #>__JUMPTAB_LOAD__
        sta $fc
        lda #<__JUMPTAB_RUN__
        sta $fd
        lda #>__JUMPTAB_RUN__
        sta $fe
        ldx #1
        jsr stub_copy
        lda #$36            ; BASIC out, KERNAL + I/O in
        sta $01
        jmp kmain
stub_copy:                  ; copy X pages ($fb) -> ($fd)
        ldy #0
@l:     lda ($fb),y
        sta ($fd),y
        iny
        bne @l
        inc $fc
        inc $fe
        dex
        bne @l
        rts

; ---------------------------------------------------------------------
.segment "RODATA"
banner: .byte "c64os 0.1 - unix-like os for the c64", 10, 0
s_mem:  .byte "memory: ", 0
s_kb:   .byte " pages free", 10, 0
s_reu:  .byte "reu: ", 0
s_reuk: .byte " x 64k", 10, 0
s_noreu: .byte "reu: none", 10, 0
s_init: .byte "/bin/init", 0
s_noinit: .byte "cannot start /bin/init", 0
s_panic: .byte 10, "kernel panic: ", 0
s_mount: .byte "cannot mount root filesystem", 0

.segment "CODE"
kmain:
        ldx #$ff
        txs
        lda #0
        sta $d020
        sta $d021
        ; clear kernel BSS
        lda #<__BSS_RUN__
        sta p1
        lda #>__BSS_RUN__
        sta p1+1
        ldx #>(__BSS_SIZE__ + 255)
        lda #0
        tay
@z:     sta (p1),y
        iny
        bne @z
        inc p1+1
        dex
        bne @z
        ldx #$1f
@zz:    sta $40,x
        dex
        bpl @zz
        lda #$ff
        sta cur
        lda #1
        sta in_kernel

        ; vectors
        lda #<irq
        sta $0314
        lda #>irq
        sta $0315
        lda #<brk_handler
        sta $0316
        lda #>brk_handler
        sta $0317
        lda #<nmi_handler
        sta $0318
        lda #>nmi_handler
        sta $0319

        jsr con_init
        lda #<banner
        ldx #>banner
        jsr con_puts_ax
        jsr mem_init
        jsr proc_init
        jsr file_init
        cli
        jsr blk_init
        lda #<s_mem
        ldx #>s_mem
        jsr con_puts_ax
        lda free_pages
        ldx #0
        jsr con_dec
        lda #<s_kb
        ldx #>s_kb
        jsr con_puts_ax
        lda reu_banks
        beq @noreu
        lda #<s_reu
        ldx #>s_reu
        jsr con_puts_ax
        lda reu_banks
        ldx #0
        jsr con_dec
        lda #<s_reuk
        ldx #>s_reuk
        jsr con_puts_ax
        jmp @mount
@noreu: lda #<s_noreu
        ldx #>s_noreu
        jsr con_puts_ax
@mount: jsr fs_mount
        bcc @ok
        lda #<s_mount
        ldx #>s_mount
        jmp panic
@ok:
        lda #<s_init
        ldx #>s_init
        jsr spawn_kernel
        bcc @run
        lda #<s_noinit
        ldx #>s_noinit
        jmp panic
@run:   sei
        jmp sched           ; never returns here (cur = $FF, nothing saved)

nmi_handler:
        rti

brk_handler:
        lda #<s_brk
        ldx #>s_brk
        ; fall through
; panic: print message (A/X) and halt
panic:
        sei
        pha
        txa
        pha
        lda #<s_panic
        ldx #>s_panic
        jsr con_puts_ax
        pla
        tax
        pla
        jsr con_puts_ax
@h:     inc $d020
        jmp @h

.segment "RODATA"
s_brk:  .byte "brk", 0
