.text
.globl _original_spread_math
_original_spread_math:
 stp d8,d9,[sp,#-32]!
 stp x29,x30,[sp,#16]
 fmov d8,d0
 fmov d9,d1
 .incbin "work/mod026-salary/TeamfightManager2.arm64",0x1017804,0x34
 bl _tanh
 .incbin "work/mod026-salary/TeamfightManager2.arm64",0x101783c,8
 ldp x29,x30,[sp,#16]
 ldp d8,d9,[sp],#32
 ret
.globl _patched_spread_math
_patched_spread_math:
 stp d8,d9,[sp,#-32]!
 stp x29,x30,[sp,#16]
 fmov d8,d0
 fmov d9,d1
 .incbin "work/mod026-salary/TeamfightManager2.transfer.arm64",0x1017804,0x34
 bl _tanh
 .incbin "work/mod026-salary/TeamfightManager2.transfer.arm64",0x101783c,8
 ldp x29,x30,[sp,#16]
 ldp d8,d9,[sp],#32
 ret
