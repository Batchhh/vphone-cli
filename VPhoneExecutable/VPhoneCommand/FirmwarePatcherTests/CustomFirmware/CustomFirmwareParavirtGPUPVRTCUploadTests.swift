// CustomFirmwareParavirtGPUPVRTCUploadTests.swift — PVRTC upload and readback.
//
// Two halves. A synthetic Mach-O carries the symbol table, the four `bl`
// calls of `_doCompressedBlit` and a zero-padded `__TEXT`, so placement,
// redirection, idempotence and the refusals are checked anywhere. The real
// cloudOS 26.4 (23E5207q) driver is the reference for the bytes: patched on
// its own, and after the heap index patch, it must hash to what was
// installed and probe-verified in a guest (72/72 PVRTC scenes pixel-identical
// to the host).
//
// The real driver is required. Point `VPHONE_MACHO_PRISTINE` at a directory
// holding `AppleParavirtGPUMetalIOGPUFamily` (from `~/.vphone/gpu-drivers/
// 26.4_23E5207q/`), or put it in `ipsws/ref_extract/macho_pristine/`. Without
// it the real-driver tests FAIL unless `VPHONE_MACHO_FIXTURE_OPTIONAL=1`.

import CryptoKit
@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

private typealias Patcher = CustomFirmwareParavirtGPUPVRTCUpload

// MARK: - Fixtures

private enum GPUDriverFixture {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let pristineSHA256 = "29ba36c7bc87d82c40fa1cecdf357e7a383fa70eb46df0d75869f5ac562aedbc"
    /// This patch alone.
    static let patchedSHA256 = "d6505ce48a4031e2bdf906c0cf9a639174d8136a7ae432fefeb1d469b8eb7712"
    /// This patch over the heap index patch — the bytes installed in a guest.
    static let composedSHA256 = "975b1b78a4933a38a6fdf535e016220b92aac77cbfc4f1866a5ac302fa21e9d8"

    static var pristine: URL? {
        let directory = ProcessInfo.processInfo.environment["VPHONE_MACHO_PRISTINE"]
            .map { URL(fileURLWithPath: $0) }
            ?? repoRoot.appendingPathComponent("ipsws/ref_extract/macho_pristine")
        let binary = directory.appendingPathComponent("AppleParavirtGPUMetalIOGPUFamily")
        return FileManager.default.fileExists(atPath: binary.path) ? binary : nil
    }

    static var runs: Bool {
        pristine != nil || ProcessInfo.processInfo.environment["VPHONE_MACHO_FIXTURE_OPTIONAL"] != "1"
    }

    static let missing: Comment = """
    the cloudOS 26.4 (23E5207q) AppleParavirtGPUMetalIOGPUFamily is required — put it at \
    ipsws/ref_extract/macho_pristine/, point VPHONE_MACHO_PRISTINE at its directory, or set \
    VPHONE_MACHO_FIXTURE_OPTIONAL=1 to skip
    """

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// A one-section Mach-O with a symbol table: `LC_SEGMENT_64` holding
/// `__TEXT,__text` followed by zero padding, and `LC_SYMTAB` naming
/// `_doCompressedBlit` inside `__text`.
private struct SyntheticDriver {
    static let textOffset = 0x100
    /// The four `bl` calls, then `_doCompressedBlit` itself.
    static let callers = (0 ..< 4).map { textOffset + 0x10 + $0 * 0x10 }
    static let compressedBlit = textOffset + 0x100
    /// The routine lands at the first 16-byte-aligned word after
    /// `_doCompressedBlit`.
    static let routineOffset = (compressedBlit + 4 + 15) & ~15
    static let textSize = 0x200
    /// Enough zero padding after `__text` for the routine.
    static let segmentSize = (routineOffset + Patcher.routineSize - textOffset + 0x100) & ~15
    /// The symbol table and its strings sit after the segment.
    static let fileSize = textOffset + segmentSize + 16 + "doCompressedBlit".utf8.count + 2

    var data: Data

    init() {
        var file = Data(count: Self.fileSize)
        func put(_ value: UInt32, at offset: Int) {
            file.replaceSubrange(offset ..< offset + 4, with: ARM64.encodeU32(value))
        }
        func put64(_ value: UInt64, at offset: Int) {
            put(UInt32(truncatingIfNeeded: value), at: offset)
            put(UInt32(truncatingIfNeeded: value >> 32), at: offset + 4)
        }
        func putName(_ name: String, at offset: Int) {
            file.replaceSubrange(offset ..< offset + name.utf8.count, with: Data(name.utf8))
        }

        let sizeofcmds = 72 + 80 + 24
        put(0xFEED_FACF, at: 0) // MH_MAGIC_64
        put(0x0100_000C, at: 4) // CPU_TYPE_ARM64
        put(2, at: 16) // ncmds
        put(UInt32(sizeofcmds), at: 20)

        // LC_SEGMENT_64 __TEXT { __text }
        let segment = 32
        put(0x19, at: segment)
        put(UInt32(72 + 80), at: segment + 4)
        putName("__TEXT", at: segment + 8)
        // vmaddr == fileOffset, so a VA maps to its own file offset.
        put64(UInt64(Self.textOffset), at: segment + 24)
        put64(UInt64(Self.segmentSize), at: segment + 32)
        put64(UInt64(Self.textOffset), at: segment + 40)
        put64(UInt64(Self.segmentSize), at: segment + 48)
        put(1, at: segment + 64) // nsects
        let section = segment + 72
        putName("__text", at: section)
        putName("__TEXT", at: section + 16)
        put64(UInt64(Self.textOffset), at: section + 32)
        put64(UInt64(Self.textSize), at: section + 40)
        put(UInt32(Self.textOffset), at: section + 48)

        // LC_SYMTAB: one nlist_64 for _doCompressedBlit.
        let strtab = "_doCompressedBlit\0"
        let symtab = segment + 72 + 80
        let symoff = Self.textOffset + Self.segmentSize
        put(0x02, at: symtab)
        put(24, at: symtab + 4)
        put(UInt32(symoff), at: symtab + 8)
        put(1, at: symtab + 12)
        put(UInt32(symoff + 16), at: symtab + 16)
        put(UInt32(strtab.utf8.count), at: symtab + 20)
        file.replaceSubrange(symoff ..< symoff + 4, with: ARM64.encodeU32(0)) // n_strx: the name starts at stroff
        put(0x0F, at: symoff + 4) // N_SECT
        put64(UInt64(Self.compressedBlit), at: symoff + 8)
        file.replaceSubrange(symoff + 16 ..< symoff + 16 + strtab.utf8.count, with: Data(strtab.utf8))

        // The code: four bl to _doCompressedBlit, and its `ret`.
        for caller in Self.callers {
            file.replaceSubrange(caller ..< caller + 4, with: ARM64Encoder.encodeBL(from: caller, to: Self.compressedBlit)!)
        }
        put(0xD65F_03C0, at: Self.compressedBlit) // ret

        data = file
    }

    func word(at offset: Int) -> UInt32 {
        data.loadLE(UInt32.self, at: offset)
    }
}

// MARK: - Synthetic

struct CustomFirmwareParavirtGPUPVRTCUploadTests {
    @Test func `The routine lands in the padding and takes over the first two calls`() throws {
        var driver = SyntheticDriver()
        let report = try Patcher.patch(&driver.data, log: nil)
        #expect(report.routineFileOffset == SyntheticDriver.routineOffset)
        #expect(report.routineState == .patched)
        #expect(report.callersWritten == 2)
        #expect(report.callers.map(\.fileOffset) == [SyntheticDriver.callers[0], SyntheticDriver.callers[1]])
        for index in 0 ..< 2 {
            let expected = ARM64Encoder.encodeBL(from: SyntheticDriver.callers[index], to: SyntheticDriver.routineOffset)
            #expect(driver.data[SyntheticDriver.callers[index] ..< SyntheticDriver.callers[index] + 4] == expected)
        }
        // The routine's own b to _doCompressedBlit is re-encoded from where
        // it landed.
        #expect(
            driver.data[SyntheticDriver.routineOffset + Patcher.routineBranchSlot
                ..< SyntheticDriver.routineOffset + Patcher.routineBranchSlot + 4]
                == ARM64Encoder.encodeB(
                    from: SyntheticDriver.routineOffset + Patcher.routineBranchSlot,
                    to: SyntheticDriver.compressedBlit,
                ),
        )
    }

    @Test func `The layout pair keeps calling the original`() throws {
        var driver = SyntheticDriver()
        try Patcher.patch(&driver.data, log: nil)
        for index in 2 ..< 4 {
            let expected = ARM64Encoder.encodeBL(from: SyntheticDriver.callers[index], to: SyntheticDriver.compressedBlit)
            #expect(driver.data[SyntheticDriver.callers[index] ..< SyntheticDriver.callers[index] + 4] == expected)
        }
    }

    @Test func `A second run recognises its own output and writes nothing`() throws {
        var driver = SyntheticDriver()
        try Patcher.patch(&driver.data, log: nil)
        let once = driver.data
        let report = try Patcher.patch(&driver.data, log: nil)
        #expect(report.routineState == .alreadyPatched)
        #expect(report.routineFileOffset == SyntheticDriver.routineOffset)
        #expect(report.callersWritten == 0)
        #expect(report.callers.allSatisfy { $0.state == .alreadyPatched })
        #expect(driver.data == once)
    }

    @Test func `The wrong number of calls refuses and changes nothing`() throws {
        var driver = SyntheticDriver()
        // A fifth call: the count no longer names this driver.
        let extra = SyntheticDriver.compressedBlit - 8
        driver.data.replaceSubrange(extra ..< extra + 4,
                                    with: ARM64Encoder.encodeBL(from: extra, to: SyntheticDriver.compressedBlit)!)
        let before = driver.data
        #expect(throws: PatcherError.self) { try Patcher.patch(&driver.data, log: nil) }
        #expect(driver.data == before)
    }

    @Test func `A missing symbol refuses`() throws {
        var driver = SyntheticDriver()
        // Drop the symbol table: zero the nlist's value, leaving the name.
        driver.data.replaceSubrange(
            SyntheticDriver.textOffset + SyntheticDriver.segmentSize + 8
                ..< SyntheticDriver.textOffset + SyntheticDriver.segmentSize + 16,
            with: Data(repeating: 0, count: 8),
        )
        #expect(throws: PatcherError.self) { try Patcher.patch(&driver.data, log: nil) }
    }

    @Test func `Padding without room for the routine refuses`() throws {
        var driver = SyntheticDriver()
        // A word just before the segment's end: the padding no longer holds
        // 320 aligned bytes.
        let segmentEnd = SyntheticDriver.textOffset + SyntheticDriver.segmentSize
        let stray = segmentEnd - 0x40
        driver.data.replaceSubrange(stray ..< stray + 4, with: ARM64.encodeU32(0xD65F_03C0))
        let before = driver.data
        #expect(throws: PatcherError.self) { try Patcher.patch(&driver.data, log: nil) }
        #expect(driver.data == before)
    }

    // MARK: - Real driver

    @Test(.enabled(if: GPUDriverFixture.runs))
    func `The 23E5207q driver patches to the verified bytes`() throws {
        let url = try #require(GPUDriverFixture.pristine, GPUDriverFixture.missing)
        var data = try Data(contentsOf: url)
        #expect(GPUDriverFixture.sha256(data) == GPUDriverFixture.pristineSHA256)
        let report = try Patcher.patch(&data, log: nil)
        #expect(report.routineFileOffset == 0x56490)
        #expect(report.routineState == .patched)
        #expect(report.callers.map(\.fileOffset) == [0x8AE8, 0x8DF4])
        #expect(GPUDriverFixture.sha256(data) == GPUDriverFixture.patchedSHA256)
        let second = try Patcher.patch(&data, log: nil)
        #expect(second.routineState == .alreadyPatched)
        #expect(second.callersWritten == 0)
        #expect(GPUDriverFixture.sha256(data) == GPUDriverFixture.patchedSHA256)
    }

    @Test(.enabled(if: GPUDriverFixture.runs))
    func `The two GPU patchers compose to the installed bytes`() throws {
        let url = try #require(GPUDriverFixture.pristine, GPUDriverFixture.missing)
        // The installer's order: the index patch stages first.
        var data = try Data(contentsOf: url)
        try CustomFirmwareParavirtGPUIndexOffset.patch(&data, log: nil)
        try Patcher.patch(&data, log: nil)
        #expect(GPUDriverFixture.sha256(data) == GPUDriverFixture.composedSHA256)

        // The reverse order composes to the same bytes: the sites are
        // disjoint.
        var reversed = try Data(contentsOf: url)
        try Patcher.patch(&reversed, log: nil)
        try CustomFirmwareParavirtGPUIndexOffset.patch(&reversed, log: nil)
        #expect(GPUDriverFixture.sha256(reversed) == GPUDriverFixture.composedSHA256)
    }
}
