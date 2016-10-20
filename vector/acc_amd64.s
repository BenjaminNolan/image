// generated by go run gen.go; DO NOT EDIT

// +build !appengine
// +build gc
// +build !noasm

#include "textflag.h"

// fl is short for floating point math. fx is short for fixed point math.

DATA flAlmost65536<>+0x00(SB)/8, $0x477fffff477fffff
DATA flAlmost65536<>+0x08(SB)/8, $0x477fffff477fffff
DATA flOne<>+0x00(SB)/8, $0x3f8000003f800000
DATA flOne<>+0x08(SB)/8, $0x3f8000003f800000
DATA flSignMask<>+0x00(SB)/8, $0x7fffffff7fffffff
DATA flSignMask<>+0x08(SB)/8, $0x7fffffff7fffffff

// scatterAndMulBy0x101 is a PSHUFB mask that brings the low four bytes of an
// XMM register to the low byte of that register's four uint32 values. It
// duplicates those bytes, effectively multiplying each uint32 by 0x101.
//
// It transforms a little-endian 16-byte XMM value from
//	ijkl????????????
// to
//	ii00jj00kk00ll00
DATA scatterAndMulBy0x101<>+0x00(SB)/8, $0x8080010180800000
DATA scatterAndMulBy0x101<>+0x08(SB)/8, $0x8080030380800202

// gather is a PSHUFB mask that brings the second-lowest byte of the XMM
// register's four uint32 values to the low four bytes of that register.
//
// It transforms a little-endian 16-byte XMM value from
//	?i???j???k???l??
// to
//	ijkl000000000000
DATA gather<>+0x00(SB)/8, $0x808080800d090501
DATA gather<>+0x08(SB)/8, $0x8080808080808080

DATA fxAlmost65536<>+0x00(SB)/8, $0x0000ffff0000ffff
DATA fxAlmost65536<>+0x08(SB)/8, $0x0000ffff0000ffff
DATA inverseFFFF<>+0x00(SB)/8, $0x8000800180008001
DATA inverseFFFF<>+0x08(SB)/8, $0x8000800180008001

GLOBL flAlmost65536<>(SB), (NOPTR+RODATA), $16
GLOBL flOne<>(SB), (NOPTR+RODATA), $16
GLOBL flSignMask<>(SB), (NOPTR+RODATA), $16
GLOBL scatterAndMulBy0x101<>(SB), (NOPTR+RODATA), $16
GLOBL gather<>(SB), (NOPTR+RODATA), $16
GLOBL fxAlmost65536<>(SB), (NOPTR+RODATA), $16
GLOBL inverseFFFF<>(SB), (NOPTR+RODATA), $16

// func haveSSE4_1() bool
TEXT ·haveSSE4_1(SB), NOSPLIT, $0
	MOVQ $1, AX
	CPUID
	SHRQ $19, CX
	ANDQ $1, CX
	MOVB CX, ret+0(FP)
	RET

// ----------------------------------------------------------------------------

// func fixedAccumulateOpOverSIMD(dst []uint8, src []uint32)
//
// XMM registers. Variable names are per
// https://github.com/google/font-rs/blob/master/src/accumulate.c
//
//	xmm0	scratch
//	xmm1	x
//	xmm2	y, z
//	xmm3	-
//	xmm4	-
//	xmm5	fxAlmost65536
//	xmm6	gather
//	xmm7	offset
//	xmm8	scatterAndMulBy0x101
//	xmm9	fxAlmost65536
//	xmm10	inverseFFFF
TEXT ·fixedAccumulateOpOverSIMD(SB), NOSPLIT, $0-48

	MOVQ dst_base+0(FP), DI
	MOVQ dst_len+8(FP), BX
	MOVQ src_base+24(FP), SI
	MOVQ src_len+32(FP), R10

	// Sanity check that len(dst) >= len(src).
	CMPQ BX, R10
	JLT  fxAccOpOverEnd

	// R10 = len(src) &^ 3
	// R11 = len(src)
	MOVQ R10, R11
	ANDQ $-4, R10

	// fxAlmost65536 := XMM(0x0000ffff repeated four times) // Maximum of an uint16.
	MOVOU fxAlmost65536<>(SB), X5

	// gather               := XMM(see above)                      // PSHUFB shuffle mask.
	// scatterAndMulBy0x101 := XMM(see above)                      // PSHUFB shuffle mask.
	// fxAlmost65536        := XMM(0x0000ffff repeated four times) // 0xffff.
	// inverseFFFF          := XMM(0x80008001 repeated four times) // Magic constant for dividing by 0xffff.
	MOVOU gather<>(SB), X6
	MOVOU scatterAndMulBy0x101<>(SB), X8
	MOVOU fxAlmost65536<>(SB), X9
	MOVOU inverseFFFF<>(SB), X10

	// offset := XMM(0x00000000 repeated four times) // Cumulative sum.
	XORPS X7, X7

	// i := 0
	MOVQ $0, R9

fxAccOpOverLoop4:
	// for i < (len(src) &^ 3)
	CMPQ R9, R10
	JAE  fxAccOpOverLoop1

	// x = XMM(s0, s1, s2, s3)
	//
	// Where s0 is src[i+0], s1 is src[i+1], etc.
	MOVOU (SI), X1

	// scratch = XMM(0, s0, s1, s2)
	// x += scratch                                  // yields x == XMM(s0, s0+s1, s1+s2, s2+s3)
	MOVOU X1, X0
	PSLLO $4, X0
	PADDD X0, X1

	// scratch = XMM(0, 0, 0, 0)
	// scratch = XMM(scratch@0, scratch@0, x@0, x@1) // yields scratch == XMM(0, 0, s0, s0+s1)
	// x += scratch                                  // yields x == XMM(s0, s0+s1, s0+s1+s2, s0+s1+s2+s3)
	XORPS  X0, X0
	SHUFPS $0x40, X1, X0
	PADDD  X0, X1

	// x += offset
	PADDD X7, X1

	// y = abs(x)
	// y >>= 2 // Shift by 2*ϕ - 16.
	// y = min(y, fxAlmost65536)
	//
	// pabsd  %xmm1,%xmm2
	// psrld  $0x2,%xmm2
	// pminud %xmm5,%xmm2
	//
	// Hopefully we'll get these opcode mnemonics into the assembler for Go
	// 1.8. https://golang.org/issue/16007 isn't exactly the same thing, but
	// it's similar.
	BYTE $0x66; BYTE $0x0f; BYTE $0x38; BYTE $0x1e; BYTE $0xd1
	BYTE $0x66; BYTE $0x0f; BYTE $0x72; BYTE $0xd2; BYTE $0x02
	BYTE $0x66; BYTE $0x0f; BYTE $0x38; BYTE $0x3b; BYTE $0xd5

	// z = convertToInt32(y)
	// No-op.

	// Blend over the dst's prior value. SIMD for i in 0..3:
	//
	// dstA := uint32(dst[i]) * 0x101
	// maskA := z@i
	// outA := dstA*(0xffff-maskA)/0xffff + maskA
	// dst[i] = uint8(outA >> 8)
	//
	// First, set X0 to dstA*(0xfff-maskA).
	MOVL   (DI), X0
	PSHUFB X8, X0
	MOVOU  X9, X11
	PSUBL  X2, X11
	PMULLD X11, X0

	// We implement uint32 division by 0xffff as multiplication by a magic
	// constant (0x800080001) and then a shift by a magic constant (47).
	// See TestDivideByFFFF for a justification.
	//
	// That multiplication widens from uint32 to uint64, so we have to
	// duplicate and shift our four uint32s from one XMM register (X0) to
	// two XMM registers (X0 and X11).
	//
	// Move the second and fourth uint32s in X0 to be the first and third
	// uint32s in X11.
	MOVOU X0, X11
	PSRLQ $32, X11

	// Multiply by magic, shift by magic.
	//
	// pmuludq %xmm10,%xmm0
	// pmuludq %xmm10,%xmm11
	BYTE  $0x66; BYTE $0x41; BYTE $0x0f; BYTE $0xf4; BYTE $0xc2
	BYTE  $0x66; BYTE $0x45; BYTE $0x0f; BYTE $0xf4; BYTE $0xda
	PSRLQ $47, X0
	PSRLQ $47, X11

	// Merge the two registers back to one, X11, and add maskA.
	PSLLQ $32, X11
	XORPS X0, X11
	PADDD X11, X2

	// As per opSrcStore4, shuffle and copy the 4 second-lowest bytes.
	PSHUFB X6, X2
	MOVL   X2, (DI)

	// offset = XMM(x@3, x@3, x@3, x@3)
	MOVOU  X1, X7
	SHUFPS $0xff, X1, X7

	// i += 4
	// dst = dst[4:]
	// src = src[4:]
	ADDQ $4, R9
	ADDQ $4, DI
	ADDQ $16, SI
	JMP  fxAccOpOverLoop4

fxAccOpOverLoop1:
	// for i < len(src)
	CMPQ R9, R11
	JAE  fxAccOpOverEnd

	// x = src[i] + offset
	MOVL  (SI), X1
	PADDD X7, X1

	// y = abs(x)
	// y >>= 2 // Shift by 2*ϕ - 16.
	// y = min(y, fxAlmost65536)
	//
	// pabsd  %xmm1,%xmm2
	// psrld  $0x2,%xmm2
	// pminud %xmm5,%xmm2
	//
	// Hopefully we'll get these opcode mnemonics into the assembler for Go
	// 1.8. https://golang.org/issue/16007 isn't exactly the same thing, but
	// it's similar.
	BYTE $0x66; BYTE $0x0f; BYTE $0x38; BYTE $0x1e; BYTE $0xd1
	BYTE $0x66; BYTE $0x0f; BYTE $0x72; BYTE $0xd2; BYTE $0x02
	BYTE $0x66; BYTE $0x0f; BYTE $0x38; BYTE $0x3b; BYTE $0xd5

	// z = convertToInt32(y)
	// No-op.

	// Blend over the dst's prior value.
	//
	// dstA := uint32(dst[0]) * 0x101
	// maskA := z
	// outA := dstA*(0xffff-maskA)/0xffff + maskA
	// dst[0] = uint8(outA >> 8)
	MOVBLZX (DI), R12
	IMULL   $0x101, R12
	MOVL    X2, R13
	MOVL    $0xffff, AX
	SUBL    R13, AX
	MULL    R12             // MULL's implicit arg is AX, and the result is stored in DX:AX.
	MOVL    $0x80008001, BX // Divide by 0xffff is to first multiply by a magic constant...
	MULL    BX              // MULL's implicit arg is AX, and the result is stored in DX:AX.
	SHRL    $15, DX         // ...and then shift by another magic constant (47 - 32 = 15).
	ADDL    DX, R13
	SHRL    $8, R13
	MOVB    R13, (DI)

	// offset = x
	MOVOU X1, X7

	// i += 1
	// dst = dst[1:]
	// src = src[1:]
	ADDQ $1, R9
	ADDQ $1, DI
	ADDQ $4, SI
	JMP  fxAccOpOverLoop1

fxAccOpOverEnd:
	RET

// ----------------------------------------------------------------------------

// func fixedAccumulateOpSrcSIMD(dst []uint8, src []uint32)
//
// XMM registers. Variable names are per
// https://github.com/google/font-rs/blob/master/src/accumulate.c
//
//	xmm0	scratch
//	xmm1	x
//	xmm2	y, z
//	xmm3	-
//	xmm4	-
//	xmm5	fxAlmost65536
//	xmm6	gather
//	xmm7	offset
//	xmm8	-
//	xmm9	-
//	xmm10	-
TEXT ·fixedAccumulateOpSrcSIMD(SB), NOSPLIT, $0-48

	MOVQ dst_base+0(FP), DI
	MOVQ dst_len+8(FP), BX
	MOVQ src_base+24(FP), SI
	MOVQ src_len+32(FP), R10

	// Sanity check that len(dst) >= len(src).
	CMPQ BX, R10
	JLT  fxAccOpSrcEnd

	// R10 = len(src) &^ 3
	// R11 = len(src)
	MOVQ R10, R11
	ANDQ $-4, R10

	// fxAlmost65536 := XMM(0x0000ffff repeated four times) // Maximum of an uint16.
	MOVOU fxAlmost65536<>(SB), X5

	// gather := XMM(see above) // PSHUFB shuffle mask.
	MOVOU gather<>(SB), X6

	// offset := XMM(0x00000000 repeated four times) // Cumulative sum.
	XORPS X7, X7

	// i := 0
	MOVQ $0, R9

fxAccOpSrcLoop4:
	// for i < (len(src) &^ 3)
	CMPQ R9, R10
	JAE  fxAccOpSrcLoop1

	// x = XMM(s0, s1, s2, s3)
	//
	// Where s0 is src[i+0], s1 is src[i+1], etc.
	MOVOU (SI), X1

	// scratch = XMM(0, s0, s1, s2)
	// x += scratch                                  // yields x == XMM(s0, s0+s1, s1+s2, s2+s3)
	MOVOU X1, X0
	PSLLO $4, X0
	PADDD X0, X1

	// scratch = XMM(0, 0, 0, 0)
	// scratch = XMM(scratch@0, scratch@0, x@0, x@1) // yields scratch == XMM(0, 0, s0, s0+s1)
	// x += scratch                                  // yields x == XMM(s0, s0+s1, s0+s1+s2, s0+s1+s2+s3)
	XORPS  X0, X0
	SHUFPS $0x40, X1, X0
	PADDD  X0, X1

	// x += offset
	PADDD X7, X1

	// y = abs(x)
	// y >>= 2 // Shift by 2*ϕ - 16.
	// y = min(y, fxAlmost65536)
	//
	// pabsd  %xmm1,%xmm2
	// psrld  $0x2,%xmm2
	// pminud %xmm5,%xmm2
	//
	// Hopefully we'll get these opcode mnemonics into the assembler for Go
	// 1.8. https://golang.org/issue/16007 isn't exactly the same thing, but
	// it's similar.
	BYTE $0x66; BYTE $0x0f; BYTE $0x38; BYTE $0x1e; BYTE $0xd1
	BYTE $0x66; BYTE $0x0f; BYTE $0x72; BYTE $0xd2; BYTE $0x02
	BYTE $0x66; BYTE $0x0f; BYTE $0x38; BYTE $0x3b; BYTE $0xd5

	// z = convertToInt32(y)
	// No-op.

	// z = shuffleTheSecondLowestBytesOfEach4ByteElement(z)
	// copy(dst[:4], low4BytesOf(z))
	PSHUFB X6, X2
	MOVL   X2, (DI)

	// offset = XMM(x@3, x@3, x@3, x@3)
	MOVOU  X1, X7
	SHUFPS $0xff, X1, X7

	// i += 4
	// dst = dst[4:]
	// src = src[4:]
	ADDQ $4, R9
	ADDQ $4, DI
	ADDQ $16, SI
	JMP  fxAccOpSrcLoop4

fxAccOpSrcLoop1:
	// for i < len(src)
	CMPQ R9, R11
	JAE  fxAccOpSrcEnd

	// x = src[i] + offset
	MOVL  (SI), X1
	PADDD X7, X1

	// y = abs(x)
	// y >>= 2 // Shift by 2*ϕ - 16.
	// y = min(y, fxAlmost65536)
	//
	// pabsd  %xmm1,%xmm2
	// psrld  $0x2,%xmm2
	// pminud %xmm5,%xmm2
	//
	// Hopefully we'll get these opcode mnemonics into the assembler for Go
	// 1.8. https://golang.org/issue/16007 isn't exactly the same thing, but
	// it's similar.
	BYTE $0x66; BYTE $0x0f; BYTE $0x38; BYTE $0x1e; BYTE $0xd1
	BYTE $0x66; BYTE $0x0f; BYTE $0x72; BYTE $0xd2; BYTE $0x02
	BYTE $0x66; BYTE $0x0f; BYTE $0x38; BYTE $0x3b; BYTE $0xd5

	// z = convertToInt32(y)
	// No-op.

	// dst[0] = uint8(z>>8)
	MOVL X2, BX
	SHRL $8, BX
	MOVB BX, (DI)

	// offset = x
	MOVOU X1, X7

	// i += 1
	// dst = dst[1:]
	// src = src[1:]
	ADDQ $1, R9
	ADDQ $1, DI
	ADDQ $4, SI
	JMP  fxAccOpSrcLoop1

fxAccOpSrcEnd:
	RET

// ----------------------------------------------------------------------------

// func fixedAccumulateMaskSIMD(buf []uint32)
//
// XMM registers. Variable names are per
// https://github.com/google/font-rs/blob/master/src/accumulate.c
//
//	xmm0	scratch
//	xmm1	x
//	xmm2	y, z
//	xmm3	-
//	xmm4	-
//	xmm5	fxAlmost65536
//	xmm6	-
//	xmm7	offset
//	xmm8	-
//	xmm9	-
//	xmm10	-
TEXT ·fixedAccumulateMaskSIMD(SB), NOSPLIT, $0-24

	MOVQ buf_base+0(FP), DI
	MOVQ buf_len+8(FP), BX
	MOVQ buf_base+0(FP), SI
	MOVQ buf_len+8(FP), R10

	// R10 = len(src) &^ 3
	// R11 = len(src)
	MOVQ R10, R11
	ANDQ $-4, R10

	// fxAlmost65536 := XMM(0x0000ffff repeated four times) // Maximum of an uint16.
	MOVOU fxAlmost65536<>(SB), X5

	// offset := XMM(0x00000000 repeated four times) // Cumulative sum.
	XORPS X7, X7

	// i := 0
	MOVQ $0, R9

fxAccMaskLoop4:
	// for i < (len(src) &^ 3)
	CMPQ R9, R10
	JAE  fxAccMaskLoop1

	// x = XMM(s0, s1, s2, s3)
	//
	// Where s0 is src[i+0], s1 is src[i+1], etc.
	MOVOU (SI), X1

	// scratch = XMM(0, s0, s1, s2)
	// x += scratch                                  // yields x == XMM(s0, s0+s1, s1+s2, s2+s3)
	MOVOU X1, X0
	PSLLO $4, X0
	PADDD X0, X1

	// scratch = XMM(0, 0, 0, 0)
	// scratch = XMM(scratch@0, scratch@0, x@0, x@1) // yields scratch == XMM(0, 0, s0, s0+s1)
	// x += scratch                                  // yields x == XMM(s0, s0+s1, s0+s1+s2, s0+s1+s2+s3)
	XORPS  X0, X0
	SHUFPS $0x40, X1, X0
	PADDD  X0, X1

	// x += offset
	PADDD X7, X1

	// y = abs(x)
	// y >>= 2 // Shift by 2*ϕ - 16.
	// y = min(y, fxAlmost65536)
	//
	// pabsd  %xmm1,%xmm2
	// psrld  $0x2,%xmm2
	// pminud %xmm5,%xmm2
	//
	// Hopefully we'll get these opcode mnemonics into the assembler for Go
	// 1.8. https://golang.org/issue/16007 isn't exactly the same thing, but
	// it's similar.
	BYTE $0x66; BYTE $0x0f; BYTE $0x38; BYTE $0x1e; BYTE $0xd1
	BYTE $0x66; BYTE $0x0f; BYTE $0x72; BYTE $0xd2; BYTE $0x02
	BYTE $0x66; BYTE $0x0f; BYTE $0x38; BYTE $0x3b; BYTE $0xd5

	// z = convertToInt32(y)
	// No-op.

	// copy(dst[:4], z)
	MOVOU X2, (DI)

	// offset = XMM(x@3, x@3, x@3, x@3)
	MOVOU  X1, X7
	SHUFPS $0xff, X1, X7

	// i += 4
	// dst = dst[4:]
	// src = src[4:]
	ADDQ $4, R9
	ADDQ $16, DI
	ADDQ $16, SI
	JMP  fxAccMaskLoop4

fxAccMaskLoop1:
	// for i < len(src)
	CMPQ R9, R11
	JAE  fxAccMaskEnd

	// x = src[i] + offset
	MOVL  (SI), X1
	PADDD X7, X1

	// y = abs(x)
	// y >>= 2 // Shift by 2*ϕ - 16.
	// y = min(y, fxAlmost65536)
	//
	// pabsd  %xmm1,%xmm2
	// psrld  $0x2,%xmm2
	// pminud %xmm5,%xmm2
	//
	// Hopefully we'll get these opcode mnemonics into the assembler for Go
	// 1.8. https://golang.org/issue/16007 isn't exactly the same thing, but
	// it's similar.
	BYTE $0x66; BYTE $0x0f; BYTE $0x38; BYTE $0x1e; BYTE $0xd1
	BYTE $0x66; BYTE $0x0f; BYTE $0x72; BYTE $0xd2; BYTE $0x02
	BYTE $0x66; BYTE $0x0f; BYTE $0x38; BYTE $0x3b; BYTE $0xd5

	// z = convertToInt32(y)
	// No-op.

	// dst[0] = uint32(z)
	MOVL X2, (DI)

	// offset = x
	MOVOU X1, X7

	// i += 1
	// dst = dst[1:]
	// src = src[1:]
	ADDQ $1, R9
	ADDQ $4, DI
	ADDQ $4, SI
	JMP  fxAccMaskLoop1

fxAccMaskEnd:
	RET

// ----------------------------------------------------------------------------

// func floatingAccumulateOpOverSIMD(dst []uint8, src []float32)
//
// XMM registers. Variable names are per
// https://github.com/google/font-rs/blob/master/src/accumulate.c
//
//	xmm0	scratch
//	xmm1	x
//	xmm2	y, z
//	xmm3	flAlmost65536
//	xmm4	flOne
//	xmm5	flSignMask
//	xmm6	gather
//	xmm7	offset
//	xmm8	scatterAndMulBy0x101
//	xmm9	fxAlmost65536
//	xmm10	inverseFFFF
TEXT ·floatingAccumulateOpOverSIMD(SB), NOSPLIT, $8-48

	MOVQ dst_base+0(FP), DI
	MOVQ dst_len+8(FP), BX
	MOVQ src_base+24(FP), SI
	MOVQ src_len+32(FP), R10

	// Sanity check that len(dst) >= len(src).
	CMPQ BX, R10
	JLT  flAccOpOverEnd

	// R10 = len(src) &^ 3
	// R11 = len(src)
	MOVQ R10, R11
	ANDQ $-4, R10

	// Prepare to set MXCSR bits 13 and 14, so that the CVTPS2PL below is
	// "Round To Zero".
	STMXCSR mxcsrOrig-8(SP)
	MOVL    mxcsrOrig-8(SP), AX
	ORL     $0x6000, AX
	MOVL    AX, mxcsrNew-4(SP)

	// flAlmost65536 := XMM(0x477fffff repeated four times) // 255.99998 * 256 as a float32.
	// flOne         := XMM(0x3f800000 repeated four times) // 1 as a float32.
	// flSignMask    := XMM(0x7fffffff repeated four times) // All but the sign bit of a float32.
	MOVOU flAlmost65536<>(SB), X3
	MOVOU flOne<>(SB), X4
	MOVOU flSignMask<>(SB), X5

	// gather               := XMM(see above)                      // PSHUFB shuffle mask.
	// scatterAndMulBy0x101 := XMM(see above)                      // PSHUFB shuffle mask.
	// fxAlmost65536        := XMM(0x0000ffff repeated four times) // 0xffff.
	// inverseFFFF          := XMM(0x80008001 repeated four times) // Magic constant for dividing by 0xffff.
	MOVOU gather<>(SB), X6
	MOVOU scatterAndMulBy0x101<>(SB), X8
	MOVOU fxAlmost65536<>(SB), X9
	MOVOU inverseFFFF<>(SB), X10

	// offset := XMM(0x00000000 repeated four times) // Cumulative sum.
	XORPS X7, X7

	// i := 0
	MOVQ $0, R9

flAccOpOverLoop4:
	// for i < (len(src) &^ 3)
	CMPQ R9, R10
	JAE  flAccOpOverLoop1

	// x = XMM(s0, s1, s2, s3)
	//
	// Where s0 is src[i+0], s1 is src[i+1], etc.
	MOVOU (SI), X1

	// scratch = XMM(0, s0, s1, s2)
	// x += scratch                                  // yields x == XMM(s0, s0+s1, s1+s2, s2+s3)
	MOVOU X1, X0
	PSLLO $4, X0
	ADDPS X0, X1

	// scratch = XMM(0, 0, 0, 0)
	// scratch = XMM(scratch@0, scratch@0, x@0, x@1) // yields scratch == XMM(0, 0, s0, s0+s1)
	// x += scratch                                  // yields x == XMM(s0, s0+s1, s0+s1+s2, s0+s1+s2+s3)
	XORPS  X0, X0
	SHUFPS $0x40, X1, X0
	ADDPS  X0, X1

	// x += offset
	ADDPS X7, X1

	// y = x & flSignMask
	// y = min(y, flOne)
	// y = mul(y, flAlmost65536)
	MOVOU X5, X2
	ANDPS X1, X2
	MINPS X4, X2
	MULPS X3, X2

	// z = convertToInt32(y)
	LDMXCSR  mxcsrNew-4(SP)
	CVTPS2PL X2, X2
	LDMXCSR  mxcsrOrig-8(SP)

	// Blend over the dst's prior value. SIMD for i in 0..3:
	//
	// dstA := uint32(dst[i]) * 0x101
	// maskA := z@i
	// outA := dstA*(0xffff-maskA)/0xffff + maskA
	// dst[i] = uint8(outA >> 8)
	//
	// First, set X0 to dstA*(0xfff-maskA).
	MOVL   (DI), X0
	PSHUFB X8, X0
	MOVOU  X9, X11
	PSUBL  X2, X11
	PMULLD X11, X0

	// We implement uint32 division by 0xffff as multiplication by a magic
	// constant (0x800080001) and then a shift by a magic constant (47).
	// See TestDivideByFFFF for a justification.
	//
	// That multiplication widens from uint32 to uint64, so we have to
	// duplicate and shift our four uint32s from one XMM register (X0) to
	// two XMM registers (X0 and X11).
	//
	// Move the second and fourth uint32s in X0 to be the first and third
	// uint32s in X11.
	MOVOU X0, X11
	PSRLQ $32, X11

	// Multiply by magic, shift by magic.
	//
	// pmuludq %xmm10,%xmm0
	// pmuludq %xmm10,%xmm11
	BYTE  $0x66; BYTE $0x41; BYTE $0x0f; BYTE $0xf4; BYTE $0xc2
	BYTE  $0x66; BYTE $0x45; BYTE $0x0f; BYTE $0xf4; BYTE $0xda
	PSRLQ $47, X0
	PSRLQ $47, X11

	// Merge the two registers back to one, X11, and add maskA.
	PSLLQ $32, X11
	XORPS X0, X11
	PADDD X11, X2

	// As per opSrcStore4, shuffle and copy the 4 second-lowest bytes.
	PSHUFB X6, X2
	MOVL   X2, (DI)

	// offset = XMM(x@3, x@3, x@3, x@3)
	MOVOU  X1, X7
	SHUFPS $0xff, X1, X7

	// i += 4
	// dst = dst[4:]
	// src = src[4:]
	ADDQ $4, R9
	ADDQ $4, DI
	ADDQ $16, SI
	JMP  flAccOpOverLoop4

flAccOpOverLoop1:
	// for i < len(src)
	CMPQ R9, R11
	JAE  flAccOpOverEnd

	// x = src[i] + offset
	MOVL  (SI), X1
	ADDPS X7, X1

	// y = x & flSignMask
	// y = min(y, flOne)
	// y = mul(y, flAlmost65536)
	MOVOU X5, X2
	ANDPS X1, X2
	MINPS X4, X2
	MULPS X3, X2

	// z = convertToInt32(y)
	LDMXCSR  mxcsrNew-4(SP)
	CVTPS2PL X2, X2
	LDMXCSR  mxcsrOrig-8(SP)

	// Blend over the dst's prior value.
	//
	// dstA := uint32(dst[0]) * 0x101
	// maskA := z
	// outA := dstA*(0xffff-maskA)/0xffff + maskA
	// dst[0] = uint8(outA >> 8)
	MOVBLZX (DI), R12
	IMULL   $0x101, R12
	MOVL    X2, R13
	MOVL    $0xffff, AX
	SUBL    R13, AX
	MULL    R12             // MULL's implicit arg is AX, and the result is stored in DX:AX.
	MOVL    $0x80008001, BX // Divide by 0xffff is to first multiply by a magic constant...
	MULL    BX              // MULL's implicit arg is AX, and the result is stored in DX:AX.
	SHRL    $15, DX         // ...and then shift by another magic constant (47 - 32 = 15).
	ADDL    DX, R13
	SHRL    $8, R13
	MOVB    R13, (DI)

	// offset = x
	MOVOU X1, X7

	// i += 1
	// dst = dst[1:]
	// src = src[1:]
	ADDQ $1, R9
	ADDQ $1, DI
	ADDQ $4, SI
	JMP  flAccOpOverLoop1

flAccOpOverEnd:
	RET

// ----------------------------------------------------------------------------

// func floatingAccumulateOpSrcSIMD(dst []uint8, src []float32)
//
// XMM registers. Variable names are per
// https://github.com/google/font-rs/blob/master/src/accumulate.c
//
//	xmm0	scratch
//	xmm1	x
//	xmm2	y, z
//	xmm3	flAlmost65536
//	xmm4	flOne
//	xmm5	flSignMask
//	xmm6	gather
//	xmm7	offset
//	xmm8	-
//	xmm9	-
//	xmm10	-
TEXT ·floatingAccumulateOpSrcSIMD(SB), NOSPLIT, $8-48

	MOVQ dst_base+0(FP), DI
	MOVQ dst_len+8(FP), BX
	MOVQ src_base+24(FP), SI
	MOVQ src_len+32(FP), R10

	// Sanity check that len(dst) >= len(src).
	CMPQ BX, R10
	JLT  flAccOpSrcEnd

	// R10 = len(src) &^ 3
	// R11 = len(src)
	MOVQ R10, R11
	ANDQ $-4, R10

	// Prepare to set MXCSR bits 13 and 14, so that the CVTPS2PL below is
	// "Round To Zero".
	STMXCSR mxcsrOrig-8(SP)
	MOVL    mxcsrOrig-8(SP), AX
	ORL     $0x6000, AX
	MOVL    AX, mxcsrNew-4(SP)

	// flAlmost65536 := XMM(0x477fffff repeated four times) // 255.99998 * 256 as a float32.
	// flOne         := XMM(0x3f800000 repeated four times) // 1 as a float32.
	// flSignMask    := XMM(0x7fffffff repeated four times) // All but the sign bit of a float32.
	MOVOU flAlmost65536<>(SB), X3
	MOVOU flOne<>(SB), X4
	MOVOU flSignMask<>(SB), X5

	// gather := XMM(see above) // PSHUFB shuffle mask.
	MOVOU gather<>(SB), X6

	// offset := XMM(0x00000000 repeated four times) // Cumulative sum.
	XORPS X7, X7

	// i := 0
	MOVQ $0, R9

flAccOpSrcLoop4:
	// for i < (len(src) &^ 3)
	CMPQ R9, R10
	JAE  flAccOpSrcLoop1

	// x = XMM(s0, s1, s2, s3)
	//
	// Where s0 is src[i+0], s1 is src[i+1], etc.
	MOVOU (SI), X1

	// scratch = XMM(0, s0, s1, s2)
	// x += scratch                                  // yields x == XMM(s0, s0+s1, s1+s2, s2+s3)
	MOVOU X1, X0
	PSLLO $4, X0
	ADDPS X0, X1

	// scratch = XMM(0, 0, 0, 0)
	// scratch = XMM(scratch@0, scratch@0, x@0, x@1) // yields scratch == XMM(0, 0, s0, s0+s1)
	// x += scratch                                  // yields x == XMM(s0, s0+s1, s0+s1+s2, s0+s1+s2+s3)
	XORPS  X0, X0
	SHUFPS $0x40, X1, X0
	ADDPS  X0, X1

	// x += offset
	ADDPS X7, X1

	// y = x & flSignMask
	// y = min(y, flOne)
	// y = mul(y, flAlmost65536)
	MOVOU X5, X2
	ANDPS X1, X2
	MINPS X4, X2
	MULPS X3, X2

	// z = convertToInt32(y)
	LDMXCSR  mxcsrNew-4(SP)
	CVTPS2PL X2, X2
	LDMXCSR  mxcsrOrig-8(SP)

	// z = shuffleTheSecondLowestBytesOfEach4ByteElement(z)
	// copy(dst[:4], low4BytesOf(z))
	PSHUFB X6, X2
	MOVL   X2, (DI)

	// offset = XMM(x@3, x@3, x@3, x@3)
	MOVOU  X1, X7
	SHUFPS $0xff, X1, X7

	// i += 4
	// dst = dst[4:]
	// src = src[4:]
	ADDQ $4, R9
	ADDQ $4, DI
	ADDQ $16, SI
	JMP  flAccOpSrcLoop4

flAccOpSrcLoop1:
	// for i < len(src)
	CMPQ R9, R11
	JAE  flAccOpSrcEnd

	// x = src[i] + offset
	MOVL  (SI), X1
	ADDPS X7, X1

	// y = x & flSignMask
	// y = min(y, flOne)
	// y = mul(y, flAlmost65536)
	MOVOU X5, X2
	ANDPS X1, X2
	MINPS X4, X2
	MULPS X3, X2

	// z = convertToInt32(y)
	LDMXCSR  mxcsrNew-4(SP)
	CVTPS2PL X2, X2
	LDMXCSR  mxcsrOrig-8(SP)

	// dst[0] = uint8(z>>8)
	MOVL X2, BX
	SHRL $8, BX
	MOVB BX, (DI)

	// offset = x
	MOVOU X1, X7

	// i += 1
	// dst = dst[1:]
	// src = src[1:]
	ADDQ $1, R9
	ADDQ $1, DI
	ADDQ $4, SI
	JMP  flAccOpSrcLoop1

flAccOpSrcEnd:
	RET

// ----------------------------------------------------------------------------

// func floatingAccumulateMaskSIMD(dst []uint32, src []float32)
//
// XMM registers. Variable names are per
// https://github.com/google/font-rs/blob/master/src/accumulate.c
//
//	xmm0	scratch
//	xmm1	x
//	xmm2	y, z
//	xmm3	flAlmost65536
//	xmm4	flOne
//	xmm5	flSignMask
//	xmm6	-
//	xmm7	offset
//	xmm8	-
//	xmm9	-
//	xmm10	-
TEXT ·floatingAccumulateMaskSIMD(SB), NOSPLIT, $8-48

	MOVQ dst_base+0(FP), DI
	MOVQ dst_len+8(FP), BX
	MOVQ src_base+24(FP), SI
	MOVQ src_len+32(FP), R10

	// Sanity check that len(dst) >= len(src).
	CMPQ BX, R10
	JLT  flAccMaskEnd

	// R10 = len(src) &^ 3
	// R11 = len(src)
	MOVQ R10, R11
	ANDQ $-4, R10

	// Prepare to set MXCSR bits 13 and 14, so that the CVTPS2PL below is
	// "Round To Zero".
	STMXCSR mxcsrOrig-8(SP)
	MOVL    mxcsrOrig-8(SP), AX
	ORL     $0x6000, AX
	MOVL    AX, mxcsrNew-4(SP)

	// flAlmost65536 := XMM(0x477fffff repeated four times) // 255.99998 * 256 as a float32.
	// flOne         := XMM(0x3f800000 repeated four times) // 1 as a float32.
	// flSignMask    := XMM(0x7fffffff repeated four times) // All but the sign bit of a float32.
	MOVOU flAlmost65536<>(SB), X3
	MOVOU flOne<>(SB), X4
	MOVOU flSignMask<>(SB), X5

	// offset := XMM(0x00000000 repeated four times) // Cumulative sum.
	XORPS X7, X7

	// i := 0
	MOVQ $0, R9

flAccMaskLoop4:
	// for i < (len(src) &^ 3)
	CMPQ R9, R10
	JAE  flAccMaskLoop1

	// x = XMM(s0, s1, s2, s3)
	//
	// Where s0 is src[i+0], s1 is src[i+1], etc.
	MOVOU (SI), X1

	// scratch = XMM(0, s0, s1, s2)
	// x += scratch                                  // yields x == XMM(s0, s0+s1, s1+s2, s2+s3)
	MOVOU X1, X0
	PSLLO $4, X0
	ADDPS X0, X1

	// scratch = XMM(0, 0, 0, 0)
	// scratch = XMM(scratch@0, scratch@0, x@0, x@1) // yields scratch == XMM(0, 0, s0, s0+s1)
	// x += scratch                                  // yields x == XMM(s0, s0+s1, s0+s1+s2, s0+s1+s2+s3)
	XORPS  X0, X0
	SHUFPS $0x40, X1, X0
	ADDPS  X0, X1

	// x += offset
	ADDPS X7, X1

	// y = x & flSignMask
	// y = min(y, flOne)
	// y = mul(y, flAlmost65536)
	MOVOU X5, X2
	ANDPS X1, X2
	MINPS X4, X2
	MULPS X3, X2

	// z = convertToInt32(y)
	LDMXCSR  mxcsrNew-4(SP)
	CVTPS2PL X2, X2
	LDMXCSR  mxcsrOrig-8(SP)

	// copy(dst[:4], z)
	MOVOU X2, (DI)

	// offset = XMM(x@3, x@3, x@3, x@3)
	MOVOU  X1, X7
	SHUFPS $0xff, X1, X7

	// i += 4
	// dst = dst[4:]
	// src = src[4:]
	ADDQ $4, R9
	ADDQ $16, DI
	ADDQ $16, SI
	JMP  flAccMaskLoop4

flAccMaskLoop1:
	// for i < len(src)
	CMPQ R9, R11
	JAE  flAccMaskEnd

	// x = src[i] + offset
	MOVL  (SI), X1
	ADDPS X7, X1

	// y = x & flSignMask
	// y = min(y, flOne)
	// y = mul(y, flAlmost65536)
	MOVOU X5, X2
	ANDPS X1, X2
	MINPS X4, X2
	MULPS X3, X2

	// z = convertToInt32(y)
	LDMXCSR  mxcsrNew-4(SP)
	CVTPS2PL X2, X2
	LDMXCSR  mxcsrOrig-8(SP)

	// dst[0] = uint32(z)
	MOVL X2, (DI)

	// offset = x
	MOVOU X1, X7

	// i += 1
	// dst = dst[1:]
	// src = src[1:]
	ADDQ $1, R9
	ADDQ $4, DI
	ADDQ $4, SI
	JMP  flAccMaskLoop1

flAccMaskEnd:
	RET
