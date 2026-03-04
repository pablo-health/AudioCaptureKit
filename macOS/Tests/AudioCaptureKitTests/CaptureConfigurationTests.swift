@testable import AudioCaptureKit
import Foundation
import Testing

@Suite("CaptureConfiguration")
struct CaptureConfigurationTests {

    let outputDir = URL(fileURLWithPath: "/tmp")

    @Test("exportRawPCM defaults to false")
    func exportRawPCM_defaultsFalse() {
        let config = CaptureConfiguration(outputDirectory: outputDir)
        #expect(config.exportRawPCM == false)
    }

    @Test("mixingStrategy defaults to .blended")
    func mixingStrategy_defaultsToBlended() {
        let config = CaptureConfiguration(outputDirectory: outputDir)
        #expect(config.mixingStrategy == .blended)
    }

    @Test("Channels 1 through 4 are valid (no throw from validate logic)")
    func channels_validRange_1Through4() {
        for ch in 1 ... 4 {
            let config = CaptureConfiguration(channels: ch, outputDirectory: outputDir)
            #expect(config.channels == ch)
        }
    }
}
