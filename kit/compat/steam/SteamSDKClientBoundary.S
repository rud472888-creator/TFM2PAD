// Statically assembled, code-signable AArch64 forwarding veneers. x0 is the
// app-owned forwarding object's address; word1 is the genuine native object.
// Preserve x1-x8, SIMD arguments, stack arguments and LR. Only ABI scratch
// x16/x17 change. A tail branch preserves every native return convention.
.text
// A normal C dlsym forwarder would change Apple's caller-relative RTLD_NEXT /
// RTLD_SELF semantics. Restore the SDK's actual LR and arguments before the
// passthrough tail branch. The helper only resolves the one concrete-handle
// target lookup itself; its two-word decision is returned in x0/x1.
.p2align 2
.globl _dlsym
_dlsym:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x0, x1, [sp, #16]
    str x8, [sp, #32]
    mov x2, x30
    bl _TFMSDKClientLookupDecision
    mov x16, x0
    mov x17, x1
    ldr x8, [sp, #32]
    ldp x0, x1, [sp, #16]
    ldp x29, x30, [sp], #48
    cbz x17, Ltfm_dlsym_result
    br x16
Ltfm_dlsym_result:
    mov x0, x16
    ret

.macro TFM_FORWARD slot
.p2align 2
.globl _TFMSDKClientForward\slot
.private_extern _TFMSDKClientForward\slot
_TFMSDKClientForward\slot:
    ldr x16, [x0, #8]
    ldr x17, [x16]
    ldr x17, [x17, #(\slot * 8)]
    mov x0, x16
    br x17
.endmacro
TFM_FORWARD 0
TFM_FORWARD 1
TFM_FORWARD 2
TFM_FORWARD 3
TFM_FORWARD 4
// Slot5 has the separately guarded, typed C ABI adapter.
TFM_FORWARD 6
TFM_FORWARD 7
TFM_FORWARD 8
TFM_FORWARD 9
TFM_FORWARD 10
TFM_FORWARD 11
TFM_FORWARD 12
TFM_FORWARD 13
TFM_FORWARD 14
TFM_FORWARD 15
TFM_FORWARD 16
TFM_FORWARD 17
TFM_FORWARD 18
TFM_FORWARD 19
TFM_FORWARD 20
TFM_FORWARD 21
TFM_FORWARD 22
TFM_FORWARD 23
TFM_FORWARD 24
TFM_FORWARD 25
TFM_FORWARD 26
TFM_FORWARD 27
TFM_FORWARD 28
TFM_FORWARD 29
TFM_FORWARD 30
TFM_FORWARD 31
TFM_FORWARD 32
TFM_FORWARD 33
TFM_FORWARD 34
TFM_FORWARD 35
TFM_FORWARD 36
TFM_FORWARD 37
TFM_FORWARD 38
TFM_FORWARD 39
TFM_FORWARD 40
TFM_FORWARD 41
