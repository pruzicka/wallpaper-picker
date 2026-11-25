import Testing
@testable import WallpaperPicker

@Suite struct RotationTests {
    @Test func avoidsRecent() {
        let all = ["a", "b", "c", "d"]
        #expect(Rotation.candidates(from: all, avoiding: ["a", "c"]) == ["b", "d"])
    }

    @Test func allRecentStillAvoidsTheLast() {
        #expect(Rotation.candidates(from: ["a", "b", "c"], avoiding: ["c", "a", "b"]) == ["a", "c"])
    }

    @Test func smallPools() {
        #expect(Rotation.candidates(from: [], avoiding: ["a"]).isEmpty)
        #expect(Rotation.candidates(from: ["a"], avoiding: ["a"]) == ["a"])
        #expect(Rotation.candidates(from: ["a", "b"], avoiding: ["a"]) == ["b"])
        #expect(Rotation.candidates(from: ["a", "b"], avoiding: ["a", "b"]) == ["a"])
    }

    @Test func intervals() {
        #expect(RotationInterval.off.seconds == nil)
        #expect(RotationInterval.m15.seconds == 900)
        #expect(RotationInterval(rawValue: "1d") == .d1)
    }
}
