import Foundation
import Testing
@testable import AudioCaptureKit

@Suite("StereoMixer Tests")
struct StereoMixerTests {

    let mixer = StereoMixer(targetSampleRate: 48000)

    @Test("Interleave two equal-length mono streams into stereo")
    func interleaveEqualLength() {
        let left: [Float] = [1.0, 2.0, 3.0, 4.0]
        let right: [Float] = [5.0, 6.0, 7.0, 8.0]
        let stereo = mixer.interleave(left: left, right: right)
        #expect(stereo.count == 8)
        #expect(stereo == [1.0, 5.0, 2.0, 6.0, 3.0, 7.0, 4.0, 8.0])
    }

    @Test("Interleave with left channel shorter pads with zeros")
    func interleaveShorterLeft() {
        let left: [Float] = [1.0, 2.0]
        let right: [Float] = [5.0, 6.0, 7.0, 8.0]
        let stereo = mixer.interleave(left: left, right: right)
        #expect(stereo.count == 8)
        #expect(stereo == [1.0, 5.0, 2.0, 6.0, 0.0, 7.0, 0.0, 8.0])
    }

    @Test("Interleave with right channel shorter pads with zeros")
    func interleaveShorterRight() {
        let left: [Float] = [1.0, 2.0, 3.0, 4.0]
        let right: [Float] = [5.0, 6.0]
        let stereo = mixer.interleave(left: left, right: right)
        #expect(stereo.count == 8)
        #expect(stereo == [1.0, 5.0, 2.0, 6.0, 3.0, 0.0, 4.0, 0.0])
    }

    @Test("Interleave empty arrays returns empty")
    func interleaveEmpty() {
        let stereo = mixer.interleave(left: [], right: [])
        #expect(stereo.isEmpty)
    }

    @Test("Interleave one empty, one non-empty")
    func interleaveOneEmpty() {
        let left: [Float] = [1.0, 2.0]
        let stereo = mixer.interleave(left: left, right: [])
        #expect(stereo.count == 4)
        #expect(stereo == [1.0, 0.0, 2.0, 0.0])
    }

    @Test("Stereo interleaving preserves frame count")
    func frameCountPreserved() {
        let frameCount = 1024
        let left = [Float](repeating: 0.5, count: frameCount)
        let right = [Float](repeating: -0.5, count: frameCount)
        let stereo = mixer.interleave(left: left, right: right)
        #expect(stereo.count == frameCount * 2)
    }

    @Test("Convert Float32 samples to Int16 PCM")
    func convertToInt16PCM() {
        let samples: [Float] = [0.0, 1.0, -1.0, 0.5, -0.5]
        let pcmData = mixer.convertToInt16PCM(samples)
        #expect(pcmData.count == samples.count * 2)

        let values = pcmData.withUnsafeBytes {
            Array($0.bindMemory(to: Int16.self))
        }
        #expect(values[0] == 0)
        #expect(values[1] == Int16.max)
        #expect(values[2] == -Int16.max)
        #expect(values[3] == Int16.max / 2)
    }

    @Test("Clamping prevents overflow in Int16 conversion")
    func clampingPreventsOverflow() {
        let samples: [Float] = [2.0, -2.0, 100.0]
        let pcmData = mixer.convertToInt16PCM(samples)
        let values = pcmData.withUnsafeBytes {
            Array($0.bindMemory(to: Int16.self))
        }
        #expect(values[0] == Int16.max)
        #expect(values[1] == -Int16.max)
        #expect(values[2] == Int16.max)
    }

    @Test("Resample from 44100 to 48000")
    func resample44100to48000() {
        let inputCount = 4410
        let input = [Float](repeating: 0.5, count: inputCount)
        let output = mixer.resample(input, from: 44100)
        let expectedCount = Int(Double(inputCount) * (48000.0 / 44100.0))
        #expect(output.count == expectedCount)
    }

    @Test("Resample same rate returns identical samples")
    func resampleSameRate() {
        let input: [Float] = [1.0, 2.0, 3.0, 4.0, 5.0]
        let output = mixer.resample(input, from: 48000)
        #expect(output == input)
    }

    @Test("Resample empty array returns empty")
    func resampleEmpty() {
        let output = mixer.resample([], from: 44100)
        #expect(output.isEmpty)
    }
}
