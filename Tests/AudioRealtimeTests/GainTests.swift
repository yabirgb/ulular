import XCTest
import CoreAudio
import AudioRealtime

final class GainTests: XCTestCase {
    private func render(gain: Float, input: [Float], missingInput: Bool = false) -> [Float] {
        let state = MTGainCreate(gain, 48_000)!
        defer { MTGainDestroy(state) }
        var source = input
        var result = [Float](repeating: 99, count: input.count)
        source.withUnsafeMutableBytes { src in
            result.withUnsafeMutableBytes { dst in
                var inputList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(src.count), mData: missingInput ? nil : src.baseAddress))
                var outputList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(dst.count), mData: dst.baseAddress))
                MTGainRender(state, &inputList, &outputList)
            }
        }
        return result
    }

    func testGainSettlesAndPreservesStereo() {
        let input = (0..<1000).flatMap { _ in [Float(0.8), Float(-0.4)] }
        let output = render(gain: 0.5, input: input)
        XCTAssertEqual(output[1998], 0.4, accuracy: 0.0001)
        XCTAssertEqual(output[1999], -0.2, accuracy: 0.0001)
        XCTAssertTrue(zip(input, output).allSatisfy { abs($1) <= abs($0) })
    }

    func testMuteAndMissingInputProduceSilence() {
        XCTAssertEqual(render(gain: 0, input: [1, -1, 1, -1]), [0, 0, 0, 0])
        XCTAssertEqual(render(gain: 1, input: [1, -1], missingInput: true), [0, 0])
    }

    func testInvalidGainIsSilent() {
        XCTAssertEqual(render(gain: .nan, input: [1, 1]), [0, 0])
    }

    func testGainCannotAmplify() {
        let output = render(gain: 10, input: [Float](repeating: 0.5, count: 2000))
        XCTAssertEqual(output.last!, 0.5, accuracy: 0.0001)
        XCTAssertTrue(output.allSatisfy { $0 <= 0.5 })
    }

    func testOutputLargerThanInputLeavesTailZeroed() {
        let state = MTGainCreate(1, 48_000)!
        defer { MTGainDestroy(state) }
        var source = [Float](repeating: 0.5, count: 2 * 600)
        var result = [Float](repeating: 99, count: 2 * 1000)
        source.withUnsafeMutableBytes { src in
            result.withUnsafeMutableBytes { dst in
                var inputList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(src.count), mData: src.baseAddress))
                var outputList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(dst.count), mData: dst.baseAddress))
                MTGainRender(state, &inputList, &outputList)
            }
        }
        XCTAssertEqual(result[1198], 0.5, accuracy: 0.0001)
        XCTAssertTrue(result[1200...].allSatisfy { $0 == 0 })
    }

    func testExtraOutputChannelsAreZeroed() {
        let state = MTGainCreate(1, 48_000)!
        defer { MTGainDestroy(state) }
        var source = [Float](repeating: 0.5, count: 2 * 1000)
        var result = [Float](repeating: 99, count: 4 * 1000)
        source.withUnsafeMutableBytes { src in
            result.withUnsafeMutableBytes { dst in
                var inputList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(src.count), mData: src.baseAddress))
                var outputList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 4, mDataByteSize: UInt32(dst.count), mData: dst.baseAddress))
                MTGainRender(state, &inputList, &outputList)
            }
        }
        for frame in 0..<1000 {
            XCTAssertEqual(result[frame * 4 + 2], 0)
            XCTAssertEqual(result[frame * 4 + 3], 0)
        }
        XCTAssertEqual(result[3996], 0.5, accuracy: 0.0001)
    }

    func testPlanarInputToInterleavedOutputAndMuteChange() {
        let state = MTGainCreate(0.5, 48_000)!
        defer { MTGainDestroy(state) }
        let inputList = AudioBufferList.allocate(maximumBuffers: 2)
        defer { inputList.unsafeMutablePointer.deallocate() }
        var left = [Float](repeating: 0.8, count: 1000)
        var right = [Float](repeating: -0.4, count: 1000)
        var result = [Float](repeating: 99, count: 2000)
        left.withUnsafeMutableBytes { l in
            right.withUnsafeMutableBytes { r in
                result.withUnsafeMutableBytes { dst in
                    inputList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(l.count), mData: l.baseAddress)
                    inputList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(r.count), mData: r.baseAddress)
                    var outputList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(dst.count), mData: dst.baseAddress))
                    MTGainRender(state, inputList.unsafePointer, &outputList)
                    let samples = dst.bindMemory(to: Float.self)
                    XCTAssertEqual(samples[1998], 0.4, accuracy: 0.0001)
                    XCTAssertEqual(samples[1999], -0.2, accuracy: 0.0001)
                    MTGainSet(state, 0)
                    MTGainRender(state, inputList.unsafePointer, &outputList)
                    XCTAssertEqual(samples[1998], 0)
                    XCTAssertEqual(samples[1999], 0)
                }
            }
        }
    }
}
