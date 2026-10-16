// CustomFirmwareParavirtGPUIndexOffsetTests.swift — the GPU driver's indexed-draw command choice.
//
// Two halves. A synthetic Mach-O carries the four selecting branches and both
// commands' setups, so resolution, the written words, idempotence and every
// refusal are checked anywhere. The real cloudOS 26.4 (23E5207q) driver is the
// reference for the bytes: patched, it must hash to what was installed and
// verified in a guest (heap index buffers at every offset draw correctly).
//
// The real driver is required. Point `VPHONE_MACHO_PRISTINE` at a directory
// holding `AppleParavirtGPUMetalIOGPUFamily` (from `~/.vphone/gpu-drivers/
// 26.4_23E5207q/`), or put it in `ipsws/ref_extract/macho_pristine/`. Without
// it the real-driver test FAILS unless `VPHONE_MACHO_FIXTURE_OPTIONAL=1`.

import CryptoKit
@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

private typealias Patcher = CustomFirmwareParavirtGPUIndexOffset

// MARK: - Fixtures

private enum GPUDriverFixture {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let pristineSHA256 = "29ba36c7bc87d82c40fa1cecdf357e7a383fa70eb46df0d75869f5ac562aedbc"
    static let patchedSHA256 = "79138287f8005569887a8cf08dfe3aa19f4a912e148a62ede04fb38ff4d66f51"

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

/// A one-section Mach-O: the header, one `LC_SEGMENT_64` holding
/// `__TEXT,__text`, and the code at ``textOffset``.
private struct SyntheticDriver {
    static let textOffset = 0x100
    static let textSize = 0x400
    /// Each site gets its own 0x80-byte slot; the full command sits 0x40 in.
    static let slot = 0x80
    static let fullCommandDistance = 0x40

    var data: Data

    init(sites: [Patcher.Site] = Patcher.sites) {
        var file = Data(count: Self.textOffset + Self.textSize)
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
        put(0xFEED_FACF, at: 0) // MH_MAGIC_64
        put(0x0100_000C, at: 4) // CPU_TYPE_ARM64
        put(1, at: 16) // ncmds
        put(72 + 80, at: 20) // sizeofcmds
        let segment = 32
        put(0x19, at: segment) // LC_SEGMENT_64
        put(72 + 80, at: segment + 4)
        putName("__TEXT", at: segment + 8)
        put64(UInt64(Self.textOffset + Self.textSize), at: segment + 32) // vmsize
        put64(UInt64(Self.textOffset + Self.textSize), at: segment + 48) // filesize
        put(1, at: segment + 64) // nsects
        let section = segment + 72
        putName("__text", at: section)
        putName("__TEXT", at: section + 16)
        put64(UInt64(Self.textOffset), at: section + 32) // addr
        put64(UInt64(Self.textSize), at: section + 40) // size
        put(UInt32(Self.textOffset), at: section + 48) // offset

        for (index, site) in sites.enumerated() {
            let branch = Self.branchOffset(index)
            // cbnz x28 / cbz w24, alternating, to the full command.
            let imm19 = UInt32(Self.fullCommandDistance / 4) << 5
            put(index % 2 == 0 ? 0xB500_0000 | imm19 | 28 : 0x3400_0000 | imm19 | 24, at: branch)
            file.replaceSubrange(branch + 4 ..< branch + 12,
                                 with: Patcher.setup(size: site.compactSize, command: site.compactCommand))
            let full = branch + Self.fullCommandDistance
            file.replaceSubrange(full ..< full + 8,
                                 with: Patcher.setup(size: site.fullSize, command: site.fullCommand))
        }

        // The baseVertex mask inside the correct-base-vertex method's full
        // command — the site at index 2 — after its setup pair.
        file.replaceSubrange(
            Self.branchOffset(2) + Self.fullCommandDistance + 8 ..< Self.branchOffset(2) + Self.fullCommandDistance + 12,
            with: ARM64.encodeU32(Patcher.baseVertexMaskWord),
        )
        data = file
    }

    static func branchOffset(_ index: Int) -> Int {
        textOffset + index * slot
    }

    func word(at offset: Int) -> UInt32 {
        data.loadLE(UInt32.self, at: offset)
    }
}

// MARK: - Synthetic

struct CustomFirmwareParavirtGPUIndexOffsetTests {
    @Test func `Every selecting branch becomes a b to the full command`() throws {
        var driver = SyntheticDriver()
        let report = try Patcher.patch(&driver.data, log: nil)
        #expect(report.sitesWritten == Patcher.sites.count)
        for index in Patcher.sites.indices {
            let branch = SyntheticDriver.branchOffset(index)
            let expected = ARM64Encoder.encodeB(from: branch, to: branch + SyntheticDriver.fullCommandDistance)
            #expect(driver.data[branch ..< branch + 4] == expected)
        }
        // The baseVertex mask becomes mov x8, x28.
        let mask = SyntheticDriver.branchOffset(2) + SyntheticDriver.fullCommandDistance + 8
        #expect(report.baseVertex.fileOffset == mask)
        #expect(report.baseVertex.state == .patched)
        #expect(driver.data[mask ..< mask + 4] == ARM64Encoder.encodeMovX(rd: 8, rm: 28))
    }

    @Test func `A second run recognises its own output and writes nothing`() throws {
        var driver = SyntheticDriver()
        try Patcher.patch(&driver.data, log: nil)
        let once = driver.data
        let report = try Patcher.patch(&driver.data, log: nil)
        #expect(report.sitesWritten == 0)
        #expect(report.sites.allSatisfy { $0.state == .alreadyPatched })
        #expect(report.baseVertex.state == .alreadyPatched)
        #expect(!report.wroteAnything)
        #expect(driver.data == once)
    }

    @Test func `A missing compact command refuses and changes nothing`() throws {
        var driver = SyntheticDriver(sites: Array(Patcher.sites.dropLast()))
        let before = driver.data
        #expect(throws: PatcherError.self) { try Patcher.patch(&driver.data, log: nil) }
        #expect(driver.data == before)
    }

    @Test func `A branch that does not reach the full command refuses`() throws {
        var driver = SyntheticDriver()
        let full = SyntheticDriver.branchOffset(2) + SyntheticDriver.fullCommandDistance
        driver.data.replaceSubrange(full ..< full + 4, with: ARM64.encodeU32(0xD503_201F)) // nop
        let before = driver.data
        #expect(throws: PatcherError.self) { try Patcher.patch(&driver.data, log: nil) }
        #expect(driver.data == before)
    }

    @Test func `A site that is neither cbz/cbnz nor b refuses`() throws {
        var driver = SyntheticDriver()
        let branch = SyntheticDriver.branchOffset(1)
        driver.data.replaceSubrange(branch ..< branch + 4, with: ARM64.encodeU32(0xD503_201F)) // nop
        #expect(throws: PatcherError.self) { try Patcher.patch(&driver.data, log: nil) }
    }

    @Test func `A missing baseVertex mask refuses and changes nothing`() throws {
        var driver = SyntheticDriver()
        let mask = SyntheticDriver.branchOffset(2) + SyntheticDriver.fullCommandDistance + 8
        driver.data.replaceSubrange(mask ..< mask + 4, with: ARM64.encodeU32(0xD503_201F)) // nop
        let before = driver.data
        #expect(throws: PatcherError.self) { try Patcher.patch(&driver.data, log: nil) }
        #expect(driver.data == before)
    }

    @Test func `Two baseVertex masks in the window refuse`() throws {
        var driver = SyntheticDriver()
        let mask = SyntheticDriver.branchOffset(2) + SyntheticDriver.fullCommandDistance + 8
        driver.data.replaceSubrange(mask + 4 ..< mask + 8, with: ARM64.encodeU32(Patcher.baseVertexMaskWord))
        #expect(throws: PatcherError.self) { try Patcher.patch(&driver.data, log: nil) }
    }

    @Test func `Branch decoding round-trips both directions`() {
        #expect(Patcher.compareBranchDisplacement(0xB500_00DC) == 0x18) // cbnz x28, +0x18
        #expect(Patcher.compareBranchDisplacement(0x3400_0178) == 0x2C) // cbz w24, +0x2c
        #expect(Patcher.compareBranchDisplacement(0xB5FF_FFE0) == -4) // cbnz x0, -4
        #expect(Patcher.branchDisplacement(0x1400_000A) == 0x28)
        #expect(Patcher.branchDisplacement(0x17FF_FFFF) == -4)
        #expect(Patcher.compareBranchDisplacement(0x1400_000A) == nil)
        #expect(Patcher.branchDisplacement(0xB500_00DC) == nil)
    }

    // MARK: - Real driver

    @Test(.enabled(if: GPUDriverFixture.runs))
    func `The 23E5207q driver patches to the verified bytes`() throws {
        let url = try #require(GPUDriverFixture.pristine, GPUDriverFixture.missing)
        var data = try Data(contentsOf: url)
        #expect(GPUDriverFixture.sha256(data) == GPUDriverFixture.pristineSHA256)
        let report = try Patcher.patch(&data, log: nil)
        #expect(report.sites.map(\.fileOffset) == [0x1421C, 0x140B0, 0x143B4, 0x143C4])
        #expect(report.sites.map(\.targetFileOffset) == [0x14234, 0x140C8, 0x143DC, 0x143F0])
        #expect(report.baseVertex.fileOffset == 0x144E0)
        #expect(GPUDriverFixture.sha256(data) == GPUDriverFixture.patchedSHA256)
        #expect(try Patcher.patch(&data, log: nil).sitesWritten == 0)
    }
}
