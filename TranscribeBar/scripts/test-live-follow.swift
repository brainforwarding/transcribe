import Foundation

@main
struct LiveFollowChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            checks += 1
        }
        var policy = LiveTranscriptFollowPolicy()
        expect(policy.followsLatest, "New capture follows latest")
        policy.observe(bottomGap: 400, motion: .none)
        expect(policy.followsLatest, "Added content must not stop following")
        policy.observe(bottomGap: 1, motion: .awayFromBottom)
        expect(!policy.followsLatest, "Even a small deliberate scroll up pauses")
        policy.observe(bottomGap: 0, motion: .none)
        expect(!policy.followsLatest, "Reflow or animation must not resume paused reading")
        policy.observe(bottomGap: 90, motion: .towardBottom)
        expect(!policy.followsLatest, "Reading above bottom stays paused")
        policy.observe(bottomGap: .nan, motion: .towardBottom)
        expect(!policy.followsLatest, "Invalid geometry cannot resume")
        policy.observe(bottomGap: .infinity, motion: .towardBottom)
        expect(!policy.followsLatest, "Unmeasured geometry cannot resume")
        policy.observe(bottomGap: 32, motion: .towardBottom)
        expect(policy.followsLatest, "Returning near bottom resumes")

        let follower = LiveTranscriptFollower()
        for _ in 0..<20 { follower.contentChanged() }
        try await Task.sleep(nanoseconds: 300_000_000)
        expect(follower.scrollPulse == 1, "Draft bursts coalesce into one follow")
        expect(follower.scrollingProgrammatically, "Own animation is marked explicitly")
        follower.contentChanged()
        follower.userInteracted(scrollingUp: true)
        expect(follower.scrollingProgrammatically, "Upward interruption retains old animation suppression")
        follower.observe(bottomGap: 0, motion: .towardBottom)
        follower.contentChanged()
        try await Task.sleep(nanoseconds: 300_000_000)
        expect(follower.scrollPulse == 1, "Residual animation at bottom cannot resume interrupted follow")
        follower.contentChanged()
        follower.observe(bottomGap: 100, motion: .towardBottom)
        try await Task.sleep(nanoseconds: 300_000_000)
        expect(follower.scrollPulse == 1, "Content while reading earlier stays still")
        follower.userInteracted(scrollingUp: false)
        follower.observe(bottomGap: 0, motion: .towardBottom)
        try await Task.sleep(nanoseconds: 300_000_000)
        expect(follower.scrollPulse == 2, "Return to bottom resumes with one coalesced follow")
        follower.contentChanged()
        follower.stop()
        try await Task.sleep(nanoseconds: 300_000_000)
        expect(follower.scrollPulse == 2, "Leaving live pane cancels pending work")
        print("PASS live follow: \(checks) offline intent, coalescing and cancellation checks")
    }
}
