@testable import AudioCaptureKit
import Foundation
import Testing

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

@Suite("StereoMixer — separateChannels and mix() dispatch")
struct StereoMixerSeparatedStrategyTests {

    let mixer = StereoMixer(targetSampleRate: 48000)

    @Test("Left channel contains only mic signal")
    func separateChannels_leftIsMicOnly() {
        let mic: [Float] = [0.5, 0.3]
        let system: [Float] = [0.1, 0.2, 0.1, 0.2]
        let result = mixer.mix(mic: mic, system: system, strategy: .separated)
        #expect(abs(result[0] - 0.5) < 1e-6) // frame 0, L
        #expect(abs(result[2] - 0.3) < 1e-6) // frame 1, L
    }

    @Test("Right channel is system mono-fold — preserves both L and R channels")
    func separateChannels_rightIsSystemMonoFold() {
        let mic: [Float] = [0.0, 0.0]
        let system: [Float] = [0.8, 0.4, 0.8, 0.4]
        let result = mixer.mix(mic: mic, system: system, strategy: .separated)
        // Right = (0.8 + 0.4) / 2 = 0.6, NOT 0.8 (L only)
        #expect(abs(result[1] - 0.6) < 1e-6) // frame 0, R
        #expect(abs(result[3] - 0.6) < 1e-6) // frame 1, R
    }

    @Test("Left channel is zero when mic is silent")
    func separateChannels_silentMic_leftIsZero() {
        let mic: [Float] = [0.0, 0.0]
        let system: [Float] = [0.5, 0.5, 0.5, 0.5]
        let result = mixer.mix(mic: mic, system: system, strategy: .separated)
        #expect(abs(result[0]) < 1e-6)
        #expect(abs(result[2]) < 1e-6)
    }

    @Test("Right channel is zero when system is silent")
    func separateChannels_silentSystem_rightIsZero() {
        let mic: [Float] = [0.5, 0.3]
        let system: [Float] = [0.0, 0.0, 0.0, 0.0]
        let result = mixer.mix(mic: mic, system: system, strategy: .separated)
        #expect(abs(result[1]) < 1e-6)
        #expect(abs(result[3]) < 1e-6)
    }

    @Test("Mic longer than system — right channel zero-padded")
    func separateChannels_micLonger_rightZeroPadded() {
        let mic: [Float] = [0.5, 0.3, 0.1]
        let system: [Float] = [0.2, 0.2] // 1 stereo frame
        let result = mixer.mix(mic: mic, system: system, strategy: .separated)
        #expect(result.count == 6) // 3 frames
        #expect(abs(result[4] - 0.1) < 1e-6) // L = mic[2]
        #expect(abs(result[5]) < 1e-6) // R = 0 (system exhausted)
    }

    @Test("System longer than mic — left channel zero-padded")
    func separateChannels_systemLonger_leftZeroPadded() {
        let mic: [Float] = [0.5] // 1 frame
        let system: [Float] = [0.2, 0.4, 0.6, 0.8, 0.2, 0.4] // 3 stereo frames
        let result = mixer.mix(mic: mic, system: system, strategy: .separated)
        #expect(result.count == 6) // 3 frames
        // frame 1 L = mic[1] = 0 (padded)
        #expect(abs(result[2]) < 1e-6)
        // frame 1 R = (0.6 + 0.8) / 2 = 0.7
        #expect(abs(result[3] - 0.7) < 1e-6)
    }

    @Test("Both inputs empty returns empty array")
    func separateChannels_bothEmpty_returnsEmpty() {
        let result = mixer.mix(mic: [], system: [], strategy: .separated)
        #expect(result.isEmpty)
    }

    @Test("mix() with .blended strategy matches legacy mixMicWithStereoSystem")
    func mix_blended_matchesLegacyBehavior() {
        let mic: [Float] = [0.5, 0.3]
        let system: [Float] = [0.1, 0.2, 0.3, 0.4]
        let legacy = mixer.mixMicWithStereoSystem(mic: mic, system: system)
        let newMethod = mixer.mix(mic: mic, system: system, strategy: .blended)
        #expect(legacy == newMethod)
    }

    @Test("mix() with .multichannel falls back to blended behavior")
    func mix_multichannel_fallsBackToBlended() {
        let mic: [Float] = [0.5, 0.3]
        let system: [Float] = [0.1, 0.2, 0.3, 0.4]
        let blended = mixer.mix(mic: mic, system: system, strategy: .blended)
        let multichannel = mixer.mix(mic: mic, system: system, strategy: .multichannel)
        #expect(blended == multichannel)
    }

    @Test("mix() with .separated produces no mic blending into right channel")
    func mix_separated_noMicInRightChannel() {
        // With silent system audio, right channel should always be zero
        let mic: [Float] = [0.5, 0.3]
        let system: [Float] = [0.0, 0.0, 0.0, 0.0]
        let result = mixer.mix(mic: mic, system: system, strategy: .separated)
        #expect(abs(result[1]) < 1e-6) // right channel, frame 0
        #expect(abs(result[3]) < 1e-6) // right channel, frame 1
    }
}
