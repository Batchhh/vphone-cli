// CustomFirmwareParavirtGPUPVRTCUpload.swift — upload and read back PVRTC whole.
//
// What the driver does. `-[AppleParavirtTexture
// replaceRegion:mipmapLevel:slice:withBytes:bytesPerRow:bytesPerImage:]` and
// its mirror `getBytes:…` hand block-compressed data to the C routine
// `_doCompressedBlit` (an exported symbol), which copies one block row at a
// time using the caller's `bytesPerRow` as the linear stride. Metal requires
// `bytesPerRow: 0` for PVRTC — a level is one blob, not rows — so with 0
// every block row is read from (or written to) row 0, and a level draws as
// the first block row repeated down the texture: vertical streaks with a
// zipper at the block edges. Free Fire keeps nearly every 3D texture in
// PVRTC (166/162, many with mipmaps), all uploaded through that path, so
// every surface smeared. There is a second fault underneath: the blob holds
// blocks in PVRTC's twiddled (Morton, y bit lowest) order while the texture
// backing expects raster order, which the host then re-twiddles — so even a
// correct stride leaves the level scrambled unless the blocks are put back
// in raster order on the way in. `Research/Guest/gpu_acceleration.md`
// ("PVRTC Uploads") has the measurements.
//
// The patch. A 320-byte leaf routine goes into the zero padding at the end
// of `__TEXT` (mapped r-x; 7 KiB are free in 23E5207q). With both strides
// non-zero — every non-PVRTC copy — it branches straight to
// `_doCompressedBlit` and the bytes it moves are unchanged. With a zero
// stride on either side and 8-byte blocks (PVRTC) it walks the twiddle
// block by block: `raster[y][x] = blob[TwiddleUV(y, x)]` going in, the
// inverse coming back. The routine's source, with the twiddle laid out, is
// `Research/Guest/pvrtc_cave.s`; the words below are its assembled form,
// frozen as a constant and verified byte for byte against the driver
// installed and probe-tested in a guest (the golden-hash tests). The two
// `bl` calls that reach `_doCompressedBlit` from the upload and the
// readback — the first two of the four the driver holds — become `bl` to
// the routine. The other two callers are `AppleParavirtTextureLayout
// copyFromLinearBytes:` / `copyFromTextureMemory:`, which no measured path
// reaches; they keep calling the original routine.
//
// Finding the sites. Nothing is a literal address:
//
//   * `_doCompressedBlit` resolves through `LC_SYMTAB` by exact name.
//   * The `bl` instructions targeting it are enumerated in `__TEXT,__text`;
//     there must be exactly four, or this is not the cloudOS 26.4 (23E5207q)
//     driver and nothing is written. The routine's own output is recognised
//     the same way: the first two sites hold `bl` to the routine instead and
//     only two callers of the original remain.
//   * The routine lands at the first 16-byte-aligned word after the last
//     non-zero word of `__TEXT` — the padding's start — and only when
//     320 zero bytes are still free inside the segment. On a re-run the
//     placed routine is found by content and left where it is.
//
// The routine is position-independent apart from the one `b` to
// `_doCompressedBlit` (the fifth word), which is re-encoded from wherever
// the routine lands; with the routine at the padding's start in 23E5207q
// the re-encoded word equals the frozen one.
//
// Composition. `CustomFirmwareParavirtGPUIndexOffset` edits the draw
// serialization well above 0x14000; this patch edits two call sites below
// 0x9000 and the segment tail. Neither can see the other's bytes, so the
// two patchers compose in either order over one staged copy of the driver.

import Foundation
import VPhonePatchKit

public enum CustomFirmwareParavirtGPUPVRTCUpload {
    public static let stdoutLog: @Sendable (String) -> Void = { print($0) }

    /// `_doCompressedBlit`, by exact symbol name.
    static let compressedBlitSymbol = "_doCompressedBlit"

    /// How many `bl` sites in `__text` reach `_doCompressedBlit` in the
    /// 23E5207q driver: the texture upload and readback, and the two
    /// `AppleParavirtTextureLayout` copies this patch leaves alone.
    static let expectedCallersOfOriginal = 4

    /// The upload (`replaceRegion:…`) and the readback (`getBytes:…`), in
    /// file-offset order, as labels for the report and the log.
    static let callerMethods = [
        "getBytes:bytesPerRow:bytesPerImage:",
        "replaceRegion:mipmapLevel:slice:withBytes:bytesPerRow:bytesPerImage:",
    ]

    static let routineSize = 320

    /// The routine's fifth word (offset 0x10) is its `b _doCompressedBlit`,
    /// re-encoded from wherever the routine lands.
    static let routineBranchSlot = 0x10

    /// `pvrtc_cave.s` assembled — see the header. Frozen, and equal to the
    /// bytes verified in a guest; the branch word is re-derived at runtime
    /// and matches the frozen one when the routine sits at the padding's
    /// start, as it does in 23E5207q.
    static let routine: [UInt32] = [
        0xF9400449, 0xF940244A, 0xB4000069, 0xB400004A,
        0x17FF1773, 0xF9400043, 0xF100207F, 0x54FFFFA1,
        0xF9401844, 0xF9401C45, 0x3941C046, 0x3941C447,
        0x8B060084, 0xD1000484, 0x9AC60884, 0x8B0700A5,
        0xD10004A5, 0x9AC708A5, 0xD2800046, 0xF100089F,
        0x9A862086, 0xD2800047, 0xF10008BF, 0x9A8720A7,
        0xEB0600FF, 0x9A8630EB, 0x1A9F27EC, 0xDAC0116D,
        0xD28007EE, 0xCB0D01CD, 0xD100056B, 0xD37FF9AE,
        0xD280000F, 0xEB0501FF, 0x540005A2, 0x8A0B01F0,
        0xAA102210, 0x92009E10, 0xAA101210, 0x9200CE10,
        0xAA100A10, 0x9200E610, 0xAA100610, 0x9200F210,
        0x3500008C, 0x9ACD25F1, 0x9ACE2231, 0xAA110210,
        0xD2800008, 0xEB04011F, 0x54000362, 0x8A0B0111,
        0xAA112231, 0x92009E31, 0xAA111231, 0x9200CE31,
        0xAA110A31, 0x9200E631, 0xAA110631, 0x9200F231,
        0xAA110611, 0x3400008C, 0x9ACD2502, 0x9ACE2042,
        0xAA020231, 0xD37DF231, 0xD37DF106, 0xB50000A9,
        0x9B0A19E6, 0xF8716807, 0xF8266827, 0x14000004,
        0x9B0919E6, 0xF8666807, 0xF8316827, 0x91000508,
        0x17FFFFE5, 0x910005EF, 0x17FFFFD3, 0xD65F03C0,
    ]

    public enum SiteState: Sendable, Equatable {
        case patched
        case alreadyPatched
    }

    /// One redirected caller: which method it belongs to, where its `bl`
    /// sits, and whether this run has to write it.
    public struct ResolvedCaller: Sendable, Equatable {
        public let method: String
        public let fileOffset: Int
        public let state: SiteState
    }

    public struct Report: Sendable, Equatable {
        /// Where the routine sits in the file.
        public let routineFileOffset: Int
        /// `.patched` when the bytes still have to go in; `.alreadyPatched`
        /// when the routine was found in place by content.
        public let routineState: SiteState
        public let callers: [ResolvedCaller]
        public var callersWritten: Int {
            callers.count(where: { $0.state == .patched })
        }
    }

    /// Patch the driver binary at `url` in place. The file is rewritten only
    /// when something changes.
    @discardableResult
    public static func patch(
        fileAt url: URL,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> Report {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PatcherError.fileNotFound(url.path)
        }
        var data = try Data(contentsOfFileToRewrite: url)
        let before = data
        let report = try patch(&data, log: log)
        if data != before {
            try data.write(to: url)
        }
        return report
    }

    /// In-memory form. `data` is left untouched unless every site resolves.
    @discardableResult
    public static func patch(
        _ data: inout Data,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> Report {
        if data.startIndex != 0 {
            data = Data(data)
        }
        let resolved = try resolve(in: data)
        if resolved.routineState == .patched {
            data.replaceSubrange(
                resolved.routineFileOffset ..< resolved.routineFileOffset + routineSize,
                with: routineBytes(at: resolved.routineFileOffset, compressedBlit: resolved.compressedBlitFileOffset),
            )
            log?("  [+] 0x\(hex(resolved.routineFileOffset)): PVRTC twiddle routine placed in the __TEXT padding")
        } else {
            log?("  [·] 0x\(hex(resolved.routineFileOffset)): PVRTC twiddle routine already in place")
        }
        for caller in resolved.callers {
            switch caller.state {
            case .patched:
                guard let bl = ARM64Encoder.encodeBL(from: caller.fileOffset, to: resolved.routineFileOffset) else {
                    throw PatcherError.patchVerificationFailed(
                        "\(caller.method) — cannot encode bl from 0x\(hex(caller.fileOffset)) to 0x\(hex(resolved.routineFileOffset))",
                    )
                }
                data.replaceSubrange(caller.fileOffset ..< caller.fileOffset + 4, with: bl)
                log?("  [+] 0x\(hex(caller.fileOffset)): \(caller.method) — bl _doCompressedBlit -> bl the twiddle routine")
            case .alreadyPatched:
                log?("  [·] 0x\(hex(caller.fileOffset)): \(caller.method) — already calls the twiddle routine")
            }
        }
        return resolved.report
    }

    /// Resolve every site, or throw without having changed anything.
    public static func resolve(in data: Data) throws -> ResolvedDriver {
        let sections = MachOParser.parseSections(from: data)
        guard let text = sections["__TEXT,__text"] else {
            throw PatcherError.invalidFormat("not a 64-bit Mach-O with a __TEXT,__text section")
        }
        let textStart = Int(text.fileOffset)
        let textEnd = textStart + Int(text.size)
        guard textStart >= 0, textEnd <= data.count, textStart < textEnd else {
            throw PatcherError.invalidFormat("__TEXT,__text lies outside the file")
        }

        let segments = MachOParser.parseSegments(from: data)
        guard let segment = segments.first(where: { $0.name == "__TEXT" }) else {
            throw PatcherError.invalidFormat("no __TEXT segment")
        }
        let segmentStart = Int(segment.fileOffset)
        let segmentEnd = min(segmentStart + Int(segment.fileSize), data.count)
        guard segmentEnd > textEnd, segmentStart >= 0 else {
            throw PatcherError.invalidFormat("__TEXT does not hold the whole of __text with room after it")
        }

        // _doCompressedBlit by exact name. `findSymbol(containing:)` would
        // happily match a longer symbol that merely contains the fragment.
        guard
            let symbolVA = MachOParser.findSymbol(named: compressedBlitSymbol, in: data),
            let compressedBlit = MachOParser.vaToFileOffset(symbolVA, segments: segments)
        else {
            throw PatcherError.patchSiteNotFound(
                "\(compressedBlitSymbol) is not in the symbol table; this is not the cloudOS 26.4 (23E5207q) driver",
            )
        }
        guard textStart <= compressedBlit, compressedBlit + 4 <= textEnd else {
            throw PatcherError.patchSiteNotFound("\(compressedBlitSymbol) lies outside __text")
        }

        let routine = try resolveRoutine(
            in: data, segment: segmentStart ..< segmentEnd, compressedBlit: compressedBlit
        )
        let callers = try resolveCallers(
            in: data, text: textStart ..< textEnd,
            compressedBlit: compressedBlit, routineOffset: routine.fileOffset
        )
        return ResolvedDriver(
            compressedBlitFileOffset: compressedBlit,
            routineFileOffset: routine.fileOffset,
            routineState: routine.state,
            callers: callers,
        )
    }

    /// Everything `patch` needs, in the shape the report carries plus the
    /// one private anchor the routine's bytes depend on.
    public struct ResolvedDriver: Sendable, Equatable {
        public let compressedBlitFileOffset: Int
        public let routineFileOffset: Int
        public let routineState: SiteState
        public let callers: [ResolvedCaller]

        public var report: Report {
            Report(
                routineFileOffset: routineFileOffset,
                routineState: routineState,
                callers: callers,
            )
        }
    }

    /// Where the routine sits: already placed — found by content, so a
    /// re-run leaves it exactly where it was — or the 16-byte-aligned start
    /// of the zero padding after the last non-zero word of `__TEXT`.
    static func resolveRoutine(
        in data: Data,
        segment: Range<Int>,
        compressedBlit: Int,
    ) throws -> (fileOffset: Int, state: SiteState) {
        // Own output: the prologue anywhere in the segment, with the whole
        // routine — its branch re-encoded from that position — matching.
        var offset = segment.lowerBound
        while offset + routineSize <= segment.upperBound {
            if data.loadLE(UInt32.self, at: offset) == routine[0],
               data.loadLE(UInt32.self, at: offset + 4) == routine[1],
               data.loadLE(UInt32.self, at: offset + 8) == routine[2],
               data.loadLE(UInt32.self, at: offset + 12) == routine[3],
               routineBytes(at: offset, compressedBlit: compressedBlit) == data[offset ..< offset + routineSize]
            {
                return (offset, .alreadyPatched)
            }
            offset += 4
        }

        // Pristine: the first 16-byte-aligned word after the last non-zero
        // word in the segment, with room for the routine.
        var lastNonZero = segment.lowerBound
        var scan = segment.upperBound - 4
        while scan > lastNonZero {
            if data.loadLE(UInt32.self, at: scan) != 0 {
                lastNonZero = scan
                break
            }
            scan -= 4
        }
        let padding = (lastNonZero + 4 + 15) & ~15
        guard padding + routineSize <= segment.upperBound else {
            throw PatcherError.patchSiteNotFound(
                "only \(segment.upperBound - (lastNonZero + 4)) bytes of __TEXT padding for a \(routineSize)-byte routine; this is not the cloudOS 26.4 (23E5207q) driver",
            )
        }
        guard data[padding ..< padding + routineSize] == Data(repeating: 0, count: routineSize) else {
            throw PatcherError.patchVerificationFailed("the __TEXT padding is not zero; it already holds something")
        }
        return (padding, .patched)
    }

    /// The four `bl` sites that reach `_doCompressedBlit` — or, on this
    /// patch's own output, the two that still do plus the two that now call
    /// the routine, which must sit below the pair that was left alone. The
    /// first two in file order are the readback and the upload.
    static func resolveCallers(
        in data: Data,
        text: Range<Int>,
        compressedBlit: Int,
        routineOffset: Int,
    ) throws -> [ResolvedCaller] {
        let toOriginal = branchLinkTargets(of: compressedBlit, in: data, range: text).sorted()
        let toRoutine = branchLinkTargets(of: routineOffset, in: data, range: text).sorted()

        // Own output: two callers still reach the original — the layout
        // pair, above — and two call the routine.
        if toOriginal.count == expectedCallersOfOriginal - 2, toRoutine.count == 2,
           toRoutine.allSatisfy { $0 < toOriginal[0] }
        {
            return zip(callerMethods, toRoutine).map { method, offset in
                ResolvedCaller(method: method, fileOffset: offset, state: .alreadyPatched)
            }
        }
        guard toRoutine.isEmpty, toOriginal.count == expectedCallersOfOriginal else {
            throw PatcherError.patchSiteNotFound(
                "expected \(expectedCallersOfOriginal) calls of \(compressedBlitSymbol) in __text, found \(toOriginal.count) (and \(toRoutine.count) of the routine); this is not the cloudOS 26.4 (23E5207q) driver",
            )
        }
        return zip(callerMethods, toOriginal.prefix(2)).map { method, offset in
            ResolvedCaller(method: method, fileOffset: offset, state: .patched)
        }
    }

    /// The routine's bytes, with the `b _doCompressedBlit` at
    /// `routineBranchSlot` encoded for where the routine actually sits.
    static func routineBytes(at routineOffset: Int, compressedBlit: Int) -> Data {
        var bytes = Data(capacity: routineSize)
        for (index, word) in routine.enumerated() {
            if index * 4 == routineBranchSlot,
               let branch = ARM64Encoder.encodeB(from: routineOffset + routineBranchSlot, to: compressedBlit)
            {
                bytes.append(branch)
            } else {
                var little = word.littleEndian
                withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
            }
        }
        return bytes
    }

    /// Every 4-byte-aligned offset in `range` holding a `bl` whose target is
    /// `destination`, in file order.
    static func branchLinkTargets(of destination: Int, in data: Data, range: Range<Int>) -> [Int] {
        var hits: [Int] = []
        var offset = range.lowerBound
        while offset + 4 <= range.upperBound {
            let word = data.loadLE(UInt32.self, at: offset)
            if word & 0xFC00_0000 == 0x9400_0000 {
                let imm26 = Int32(bitPattern: (word & 0x03FF_FFFF) << 6) >> 6
                if offset + Int(imm26) * 4 == destination {
                    hits.append(offset)
                }
            }
            offset += 4
        }
        return hits
    }

    static func hex(_ value: some BinaryInteger) -> String {
        String(value, radix: 16)
    }
}
