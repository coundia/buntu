import Testing
import Foundation
@testable import CndIptvApp

@Suite("Auto-Framerate Matching (AFR) & Dynamic Range Tests (PRD-25)")
struct DisplayRateMatcherTests {

    @Test func testStandardFrameRateSnapping() {
        // Standard film rates
        #expect(StandardFrameRate.snap(rawFps: 23.976) == .fps23_976)
        #expect(StandardFrameRate.snap(rawFps: 23.98) == .fps23_976)
        #expect(StandardFrameRate.snap(rawFps: 24.0) == .fps24)
        #expect(StandardFrameRate.snap(rawFps: 24.02) == .fps24)

        // PAL broadcast
        #expect(StandardFrameRate.snap(rawFps: 25.0) == .fps25)
        #expect(StandardFrameRate.snap(rawFps: 25.001) == .fps25)
        #expect(StandardFrameRate.snap(rawFps: 50.0) == .fps50)

        // NTSC broadcast
        #expect(StandardFrameRate.snap(rawFps: 29.97) == .fps29_97)
        #expect(StandardFrameRate.snap(rawFps: 29.971) == .fps29_97)
        #expect(StandardFrameRate.snap(rawFps: 30.0) == .fps30)
        #expect(StandardFrameRate.snap(rawFps: 59.94) == .fps59_94)
        #expect(StandardFrameRate.snap(rawFps: 60.0) == .fps60)

        // Invalid or extreme rates
        #expect(StandardFrameRate.snap(rawFps: 5.0) == nil)
        #expect(StandardFrameRate.snap(rawFps: 42.0) == nil)
        #expect(StandardFrameRate.snap(rawFps: 144.0) == nil)
    }

    @Test func testDisplayDescription() {
        #expect(StandardFrameRate.fps23_976.displayDescription == "23,976 i/s")
        #expect(StandardFrameRate.fps24.displayDescription == "24 i/s")
        #expect(StandardFrameRate.fps25.displayDescription == "25 i/s")
        #expect(StandardFrameRate.fps50.displayDescription == "50 i/s")
        #expect(StandardFrameRate.fps60.displayDescription == "60 i/s")
    }

    @Test func testDynamicRangeDetection() {
        #expect(VideoDynamicRange.detect(gamma: "smpte2084", primaries: "bt2020") == .hdr10)
        #expect(VideoDynamicRange.detect(gamma: "pq", primaries: nil) == .hdr10)
        #expect(VideoDynamicRange.detect(gamma: "arib-std-b67", primaries: "bt2020") == .hlg)
        #expect(VideoDynamicRange.detect(gamma: "hlg", primaries: nil) == .hlg)
        #expect(VideoDynamicRange.detect(gamma: "bt709", primaries: "bt709") == .sdr)
        #expect(VideoDynamicRange.detect(gamma: nil, primaries: nil) == .sdr)
    }

    @Test func testDisplayFormatInfoSummary() {
        let info = DisplayFormatInfo(rawFps: 23.976, dynamicRange: .hdr10)
        #expect(info.summary == "23,976 i/s · HDR10")

        let sdr50 = DisplayFormatInfo(rawFps: 50.0, dynamicRange: .sdr)
        #expect(sdr50.summary == "50 i/s · SDR")
    }

    @Test @MainActor func testMatcherStateAndReset() {
        let matcher = DisplayRateMatcher.shared
        matcher.update(rawFps: 23.976, gamma: "pq", primaries: "bt2020")

        #expect(matcher.currentFormat?.matchedRate == .fps23_976)
        #expect(matcher.currentFormat?.dynamicRange == .hdr10)

        matcher.reset()
        #expect(matcher.currentFormat == nil)
        #expect(matcher.isRateMatched == false)
    }
}

