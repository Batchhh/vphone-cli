// PVRTC copy for AppleParavirtGPUMetalIOGPUFamily 23E5207q, placed in the zero padding at
// the end of __TEXT (file offset 0x56490). Called instead of _doCompressedBlit (0x1c26c)
// by -[AppleParavirtTexture replaceRegion:...] (0x8df4) and getBytes:... (0x8ae8), with the
// same arguments: x0 = source, x1 = destination, x2 = copy descriptor:
//   +0x00 block bytes   +0x08 src bytes/row   +0x30 width   +0x38 height
//   +0x48 dst bytes/row +0x70 block width (byte) +0x71 block height (byte)
// Metal passes bytesPerRow 0 for PVRTC: the caller's buffer holds the level as PVRTC's
// twiddled (Morton, y bit lowest) block order. The texture backing holds blocks in raster
// order (the host twiddles it when it uploads). So with a zero stride on one side, copy
// block by block through the twiddle; anything else goes to the original routine.
// Leaf function: uses only x0-x17, no stack.
.text
.globl _cave
.p2align 2
_cave:
    ldr   x9, [x2, #0x8]          // src bytes per row (0: src is a PVRTC blob)
    ldr   x10, [x2, #0x48]        // dst bytes per row (0: dst is a PVRTC blob)
    cbz   x9, 1f
    cbz   x10, 1f
0:  b     0b                      // patched: b _doCompressedBlit
1:  ldr   x3, [x2]                // block bytes
    cmp   x3, #8                  // PVRTC blocks are 8 bytes
    b.ne  0b
    ldr   x4, [x2, #0x30]         // width
    ldr   x5, [x2, #0x38]         // height
    ldrb  w6, [x2, #0x70]         // block width
    ldrb  w7, [x2, #0x71]         // block height
    add   x4, x4, x6
    sub   x4, x4, #1
    udiv  x4, x4, x6              // bx: blocks per row
    add   x5, x5, x7
    sub   x5, x5, #1
    udiv  x5, x5, x7              // by: block rows
    mov   x6, #2
    cmp   x4, #2
    csel  x6, x4, x6, hs          // pbx = max(bx, 2): the PVRTC block grid is at least 2x2
    mov   x7, #2
    cmp   x5, #2
    csel  x7, x5, x7, hs          // pby = max(by, 2)
    cmp   x7, x6
    csel  x11, x7, x6, lo         // m = min(pby, pbx)
    cset  w12, lo                 // high index bits come from x when pby < pbx, else from y
    clz   x13, x11
    mov   x14, #63
    sub   x13, x14, x13           // s = log2(m)
    sub   x11, x11, #1            // mask = m - 1
    lsl   x14, x13, #1            // 2s
    mov   x15, #0                 // y
2:  cmp   x15, x5
    b.hs  9f
    and   x16, x15, x11           // ty = spread(y & mask) (| (y >> s) << 2s)
    orr   x16, x16, x16, lsl #8
    and   x16, x16, #0x00ff00ff00ff00ff
    orr   x16, x16, x16, lsl #4
    and   x16, x16, #0x0f0f0f0f0f0f0f0f
    orr   x16, x16, x16, lsl #2
    and   x16, x16, #0x3333333333333333
    orr   x16, x16, x16, lsl #1
    and   x16, x16, #0x5555555555555555
    cbnz  w12, 3f
    lsr   x17, x15, x13
    lsl   x17, x17, x14
    orr   x16, x16, x17
3:  mov   x8, #0                  // x
4:  cmp   x8, x4
    b.hs  8f
    and   x17, x8, x11            // tx = spread(x & mask)
    orr   x17, x17, x17, lsl #8
    and   x17, x17, #0x00ff00ff00ff00ff
    orr   x17, x17, x17, lsl #4
    and   x17, x17, #0x0f0f0f0f0f0f0f0f
    orr   x17, x17, x17, lsl #2
    and   x17, x17, #0x3333333333333333
    orr   x17, x17, x17, lsl #1
    and   x17, x17, #0x5555555555555555
    orr   x17, x16, x17, lsl #1   // twiddled index
    cbz   w12, 5f
    lsr   x2, x8, x13
    lsl   x2, x2, x14
    orr   x17, x17, x2
5:  lsl   x17, x17, #3            // blob byte offset
    lsl   x6, x8, #3              // x * 8
    cbnz  x9, 6f
    madd  x6, x15, x10, x6        // upload: raster offset in dst
    ldr   x7, [x0, x17]
    str   x7, [x1, x6]
    b     7f
6:  madd  x6, x15, x9, x6         // readback: raster offset in src
    ldr   x7, [x0, x6]
    str   x7, [x1, x17]
7:  add   x8, x8, #1
    b     4b
8:  add   x15, x15, #1
    b     2b
9:  ret
