// FirmwareGuestPatchResolutionTests.swift — The guest-half selection resolver.
//
// `FirmwareGuestPatchResolution` decides which patches the guest half of an
// install applies now: the boot chain as the plan recorded it, the guest half
// as the current selection resolves it. These tests pin that split and the
// membership of the guest-target set against the real bundled catalogue.

import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("Guest patch resolution")
struct FirmwareGuestPatchResolutionTests {
    @Test
    func `TV selection keeps vphoned and excludes iOS payloads and cache patches`() throws {
        let standard = try VPhonePatchPlan.resolve(
            preset: FirmwarePatchSetCatalog.standardPreset,
            patchSets: FirmwarePatchSetCatalog.bundled,
            iOSBase: VPhoneVersion("26.4"),
            cloudOS: VPhoneVersion("26.4"),
        )
        let unvalidated = FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: standard.enabled)
        #expect(!unvalidated.contains("system-vphoned-boot-install"))
        #expect(!unvalidated.contains("system-launchd_cache_loader-boot-unsecure_cache_gate"))
        #expect(unvalidated.contains("system-launchdaemons-boot-environment"))
        #expect(unvalidated.contains("system-extensions-boot-gpu_bundle"))
        #expect(unvalidated.contains(FirmwareGuestSystemPatchSet.paravirtGPUIndexOffset))
        #expect(unvalidated.contains(FirmwareGuestSystemPatchSet.paravirtGPUPVRTCUpload))
        #expect(unvalidated.contains("dyld-cfw-camera"))
        #expect(!unvalidated.contains("system-seputil-boot-gigalocker_uuid"))
        #expect(!unvalidated.contains("system-gigalocker-boot-rename"))
        let serial = standard.enabled.subtracting(unvalidated)
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: serial).isEmpty)
        #expect(serial.intersection(FirmwareGuestPatchResolution.guestTargetIdentifiers)
            == FirmwareGuestPatchResolution.tvSupportedGuestPatches.subtracting([FirmwareGuestSystemPatchSet.tvTPRO]))
        #expect(serial.subtracting(FirmwareGuestPatchResolution.guestTargetIdentifiers)
            == standard.enabled.subtracting(FirmwareGuestPatchResolution.guestTargetIdentifiers))
    }

    @Test
    func `TV TPRO is opt in and retains the TV guest guard`() throws {
        let identifier = FirmwareGuestSystemPatchSet.tvTPRO
        let standard = try VPhonePatchPlan.resolve(
            preset: FirmwarePatchSetCatalog.standardPreset,
            patchSets: FirmwarePatchSetCatalog.bundled,
            iOSBase: VPhoneVersion("26.4"), cloudOS: VPhoneVersion("26.4"),
        )
        #expect(!standard.enabled.contains(identifier))
        let serial = standard.enabled.subtracting(
            FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: standard.enabled),
        ).union([identifier])
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: serial).isEmpty)
        #expect(serial.contains("system-vphoned-boot-install"))
        #expect(!serial.contains("system-extensions-boot-gpu_bundle"))
    }

    @Test
    func `only an arm64e TV admits the GPU driver and the OTA userland`() {
        let gpu = "system-extensions-boot-gpu_bundle"
        let ota = FirmwareGuestSystemPatchSet.tvOTAUserland
        let selection: Set<String> = [gpu, ota, "system-vphoned-boot-install"]
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: selection) == [gpu, ota].sorted())
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: selection, arm64eUserland: true).isEmpty)
        // The iOS payloads stay out for both.
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: ["dyld-cfw-camera"], arm64eUserland: true) == ["dyld-cfw-camera"])
    }

    @Test
    func `the Apple TV 4K preset swaps in the OTA userland with the GPU driver and no TPRO patches`() throws {
        let gpu = "system-extensions-boot-gpu_bundle"
        let ota = FirmwareGuestSystemPatchSet.tvOTAUserland
        let tpro: Set = [FirmwareGuestSystemPatchSet.tvTPRO, FirmwareKernelCustomFirmwarePatchSet.tvTPROPagers]
        func plan(_ preset: VPhonePatchPreset) throws -> VPhonePatchPlan {
            try VPhonePatchPlan.resolve(
                preset: preset,
                patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion("26.6"),
                cloudOS: VPhoneVersion("26.4"),
            )
        }
        let tv4K = try plan(FirmwarePatchSetCatalog.tvOS4KPreset)
        #expect(tv4K.isEnabled(gpu) && tv4K.isEnabled(ota))
        #expect(tv4K.enabled.isDisjoint(with: tpro))
        #expect(tv4K.isEnabled("system-vphoned-boot-install"))
        // The upstream GPU heap index patch stays out, as for every TV guest.
        #expect(!tv4K.isEnabled(FirmwareGuestSystemPatchSet.paravirtGPUIndexOffset))
        #expect(!tv4K.isEnabled(FirmwareGuestSystemPatchSet.paravirtGPUPVRTCUpload))
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: tv4K.enabled, arm64eUserland: true).isEmpty)
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: tv4K.enabled) == [gpu, ota].sorted())
        // The 27 shared-cache patches are on but meet only a 27 userland.
        #expect(tv4K.enabled.isDisjoint(with: FirmwarePatchSetCatalog.tvOS27UserlandPatches))
        let tv4K27 = try VPhonePatchPlan.resolve(
            preset: FirmwarePatchSetCatalog.tvOS4KPreset,
            patchSets: FirmwarePatchSetCatalog.bundled,
            iOSBase: VPhoneVersion("27.0"),
            cloudOS: VPhoneVersion("26.4"),
        )
        // The userland swap and the GPU driver carry on to the 27 OTA.
        #expect(tv4K27.isEnabled(gpu) && tv4K27.isEnabled(ota))
        #expect(tv4K27.enabled.isSuperset(of: FirmwarePatchSetCatalog.tvOS27UserlandPatches))
        #expect(tv4K27.isEnabled("kernel-boot-iomfb_swapend"))
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: tv4K27.enabled, arm64eUserland: true).isEmpty)

        // The HD's preset is the mirror image.
        let tvHD = try plan(FirmwarePatchSetCatalog.tvOSPreset)
        #expect(!tvHD.isEnabled(gpu) && !tvHD.isEnabled(ota))
        #expect(tvHD.enabled.isSuperset(of: tpro))
        // Otherwise the two agree.
        #expect(tv4K.enabled.symmetricDifference(tvHD.enabled) == tpro.union([gpu, ota]))
    }

    @Test
    func `TV TPRO patches apply to every tvOS 26 userland on the 26.4 kernel`() throws {
        let tv: Set = [FirmwareGuestSystemPatchSet.tvTPRO, FirmwareKernelCustomFirmwarePatchSet.tvTPROPagers]
        for build in ["26.4", "26.6"] {
            let plan = try VPhonePatchPlan.resolve(
                preset: FirmwarePatchSetCatalog.standardPreset,
                patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion(build),
                cloudOS: VPhoneVersion("26.4"),
                allowed: tv,
            )
            #expect(plan.enabled.isSuperset(of: tv), "\(build)")
            #expect(plan.skippedByVersion.isDisjoint(with: tv), "\(build)")
        }
    }

    @Test
    func `Guest target identifiers include the guest patches and exclude the boot chain`() {
        let guest = FirmwareGuestPatchResolution.guestTargetIdentifiers

        // A dyld-cache patch, a guest Mach-O, a guest file, and a Preboot
        // device-tree patch are all guest-half.
        #expect(guest.contains("dyld-boot-lockdown_mode"))
        #expect(guest.contains("system-seputil-boot-gigalocker_uuid"))
        #expect(guest.contains("system-vphoned-boot-install"))
        #expect(guest.contains(FirmwareGuestSystemPatchSet.prebootHaptics))
        #expect(guest.contains(FirmwareGuestIdentityPatchSet.prebootDeviceTreeIdentity))

        // Every boot-chain patch is excluded: those are `fw patch`'s, not the
        // guest half's.
        for declaration in FirmwarePatchSetCatalog.allDeclarations where declaration.target.isBootChain {
            #expect(!guest.contains(declaration.identifier), "\(declaration.identifier) is boot-chain")
        }

        // And the set is exactly the non-boot-chain declarations.
        let expected = Set(
            FirmwarePatchSetCatalog.allDeclarations
                .filter { !$0.target.isBootChain }
                .map(\.identifier),
        )
        #expect(guest == expected)
    }

    @Test
    func `Effective enabled keeps boot chain from the plan and guest half from the selection`() {
        let guest = FirmwareGuestPatchResolution.guestTargetIdentifiers
        let bootChain = Set(
            FirmwarePatchSetCatalog.allDeclarations
                .filter(\.target.isBootChain)
                .map(\.identifier),
        )
        guard
            let boot = bootChain.first,
            let guestOn = guest.first,
            let guestOff = guest.dropFirst().first
        else {
            Issue.record("the bundled catalogue has too few patches to exercise the split")
            return
        }

        // The plan had a boot patch and one guest patch on; the selection now
        // has a *different* guest patch on and the old one off.
        let planEnabled: Set<String> = [boot, guestOn]
        let selectionEnabled: Set<String> = [guestOff]

        let effective = FirmwareGuestPatchResolution.effectiveEnabled(
            planEnabled: planEnabled,
            selectionEnabled: selectionEnabled,
        )

        #expect(effective.contains(boot), "the boot patch stays from the plan")
        #expect(effective.contains(guestOff), "a guest patch the selection turned on comes in")
        #expect(!effective.contains(guestOn), "a guest patch the selection turned off drops out")
    }

    @Test
    func `A boot-chain selection cannot add or drop guest patches`() {
        let guest = FirmwareGuestPatchResolution.guestTargetIdentifiers
        guard let guestID = guest.first else {
            Issue.record("no guest patches in the catalogue")
            return
        }
        // The selection resolves the guest patch off but names a boot patch the
        // plan never had: the boot side is the plan's alone, so nothing from the
        // selection's boot choices leaks in.
        let planEnabled: Set<String> = [guestID]
        let selectionEnabled: Set<String> = []
        let effective = FirmwareGuestPatchResolution.effectiveEnabled(
            planEnabled: planEnabled,
            selectionEnabled: selectionEnabled,
        )
        #expect(effective.isEmpty, "the guest patch drops and no boot patch is invented")
    }

    @Test
    func `Guest patches off is the guest set minus the selection`() {
        let guest = FirmwareGuestPatchResolution.guestTargetIdentifiers
        guard let on = guest.first else {
            Issue.record("no guest patches in the catalogue")
            return
        }
        let off = FirmwareGuestPatchResolution.guestPatchesOff(selectionEnabled: [on])
        #expect(!off.contains(on))
        #expect(off == guest.subtracting([on]))
    }
}
