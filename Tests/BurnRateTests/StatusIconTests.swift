import BurnRateCore
import Testing

struct StatusIconTests {
    @Test func needleAngleRestPoseAndExtremes() {
        #expect(StatusIcon.needleAngle(forRemaining: nil) == 18)   // rest pose at 70%
        #expect(StatusIcon.needleAngle(forRemaining: 100) == 0)
        #expect(StatusIcon.needleAngle(forRemaining: 70) == 18)
        #expect(StatusIcon.needleAngle(forRemaining: 0) == 60)
        #expect(StatusIcon.needleAngle(forRemaining: 200) == 0)    // clamped high
        #expect(StatusIcon.needleAngle(forRemaining: -50) == 60)   // clamped low
    }

    @Test func tintHitsTheSeverityStops() {
        let green = StatusIcon.tint(forRemaining: 80)
        #expect(green.top == RGBColor(red: 0x8F / 255, green: 0xE0 / 255, blue: 0x7A / 255))
        #expect(green.bottom == RGBColor(red: 0x33 / 255, green: 0xAE / 255, blue: 0x70 / 255))

        let red = StatusIcon.tint(forRemaining: 5)
        #expect(red.top == RGBColor(red: 0xFF / 255, green: 0x8A / 255, blue: 0x5C / 255))
        #expect(red.bottom == RGBColor(red: 0xE6 / 255, green: 0x40 / 255, blue: 0x19 / 255))
    }

    @Test func tintInterpolatesBetweenStops() {
        // 50% is halfway between the green (55) and amber (45) stops.
        let mid = StatusIcon.tint(forRemaining: 50).top
        #expect(abs(mid.red - (0x8F + 0xFF) / 2 / 255) < 0.001)
        #expect(abs(mid.green - (0xE0 + 0xC2) / 2 / 255) < 0.001)
        #expect(abs(mid.blue - (0x7A + 0x4B) / 2 / 255) < 0.001)
    }

    @Test func tintClampsOutOfRange() {
        #expect(StatusIcon.tint(forRemaining: 150) == StatusIcon.tint(forRemaining: 100))
        #expect(StatusIcon.tint(forRemaining: -20) == StatusIcon.tint(forRemaining: 0))
    }
}
