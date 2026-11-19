import Foundation
import Testing
@testable import ElisCore

@Suite struct PhoneLinkSchedulerTests {
    private func bytes(_ count: Int, _ value: UInt8 = 1) -> Data { Data(repeating: value, count: count) }

    @Test func controlBeforeEventsBeforeOpened() {
        var scheduler = PhoneLinkScheduler(window: 100, bufferLimit: 1000)
        scheduler.open(channel: 2)
        _ = scheduler.enqueue(channel: 2, bytes(1))
        _ = scheduler.enqueue(channel: 1, bytes(1))
        _ = scheduler.enqueue(channel: 0, bytes(1))
        #expect(scheduler.next(maxChunk: 10)?.channel == 0)
        #expect(scheduler.next(maxChunk: 10)?.channel == 1)
        #expect(scheduler.next(maxChunk: 10)?.channel == 2)
        #expect(scheduler.next(maxChunk: 10) == nil)
    }

    @Test func windowSpentCountsFromTheLastGrantAcrossReopen() {
        var scheduler = PhoneLinkScheduler(window: 10, bufferLimit: 1000)
        scheduler.open(channel: 2)
        _ = scheduler.enqueue(channel: 2, bytes(25))
        _ = scheduler.next(maxChunk: 6)
        #expect(!scheduler.windowSpent(channel: 2))
        _ = scheduler.next(maxChunk: 6)
        #expect(scheduler.windowSpent(channel: 2))
        // a reopen (RESYNC) refills the credit but is no CREDIT from the phone
        scheduler.open(channel: 2)
        #expect(scheduler.windowSpent(channel: 2))
        scheduler.grant(channel: 2, bytes: 4)
        #expect(!scheduler.windowSpent(channel: 2))
        scheduler.close(channel: 2)
        scheduler.open(channel: 2)
        #expect(!scheduler.windowSpent(channel: 2))
    }

    @Test func noCreditDoesNotBlockControl() {
        var scheduler = PhoneLinkScheduler(window: 0, bufferLimit: 1000)
        scheduler.open(channel: 2)
        _ = scheduler.enqueue(channel: 2, bytes(5))
        _ = scheduler.enqueue(channel: 0, bytes(3))
        #expect(scheduler.next(maxChunk: 10) == .data(channel: 0, bytes(3)))
        #expect(scheduler.next(maxChunk: 10) == nil)
        #expect(scheduler.pendingBytes == 5)
    }

    @Test func chunkLimitedByCredit() {
        var scheduler = PhoneLinkScheduler(window: 10, bufferLimit: 1000)
        scheduler.open(channel: 2)
        _ = scheduler.enqueue(channel: 2, bytes(25))
        #expect(scheduler.next(maxChunk: 100)?.payload.count == 10)
        #expect(scheduler.next(maxChunk: 100) == nil)
        scheduler.grant(channel: 2, bytes: 10)
        #expect(scheduler.next(maxChunk: 100)?.payload.count == 10)
        scheduler.grant(channel: 2, bytes: 10)
        #expect(scheduler.next(maxChunk: 100)?.payload.count == 5)
        #expect(scheduler.next(maxChunk: 100) == nil)
    }

    @Test func controlChunkedByMaxChunkWithoutCredit() {
        var scheduler = PhoneLinkScheduler(window: 0, bufferLimit: 10)
        _ = scheduler.enqueue(channel: 0, bytes(100))
        #expect(scheduler.next(maxChunk: 60)?.payload.count == 60)
        #expect(scheduler.next(maxChunk: 60)?.payload.count == 40)
        #expect(scheduler.next(maxChunk: 60) == nil)
    }

    @Test func openedChannelsRoundRobin() {
        var scheduler = PhoneLinkScheduler(window: 100, bufferLimit: 1000)
        scheduler.open(channel: 2)
        scheduler.open(channel: 3)
        _ = scheduler.enqueue(channel: 2, bytes(4))
        _ = scheduler.enqueue(channel: 3, bytes(4))
        let order = (0..<4).compactMap { _ in scheduler.next(maxChunk: 2)?.channel }
        #expect(order == [2, 3, 2, 3])
        #expect(scheduler.next(maxChunk: 2) == nil)
    }

    @Test func aLowChannelWaitsForVt() {
        var scheduler = PhoneLinkScheduler(window: 100, bufferLimit: 1000)
        scheduler.open(channel: 3, low: true)
        scheduler.open(channel: 2)
        _ = scheduler.enqueue(channel: 3, bytes(4))
        _ = scheduler.enqueue(channel: 2, bytes(4))
        _ = scheduler.enqueue(channel: 1, bytes(1))
        _ = scheduler.enqueue(channel: 0, bytes(1))
        let order = (0..<6).compactMap { _ in scheduler.next(maxChunk: 2)?.channel }
        #expect(order == [0, 1, 2, 2, 3, 3])
        #expect(scheduler.next(maxChunk: 2) == nil)
    }

    @Test func aLowChannelGetsOneFrameInNine() {
        var scheduler = PhoneLinkScheduler(window: 10_000, bufferLimit: 10_000)
        scheduler.open(channel: 2)
        scheduler.open(channel: 3, low: true)
        _ = scheduler.enqueue(channel: 2, bytes(1000))
        _ = scheduler.enqueue(channel: 3, bytes(1000))
        let order = (0..<27).compactMap { _ in scheduler.next(maxChunk: 1)?.channel }
        let expected = Array([[UInt32]](repeating: Array(repeating: 2, count: 8) + [3], count: 3).joined())
        #expect(order == expected)
    }

    @Test func aLowChannelTakesEveryPickWhileVtIsIdle() {
        var scheduler = PhoneLinkScheduler(window: 100, bufferLimit: 1000)
        scheduler.open(channel: 2)
        scheduler.open(channel: 3, low: true)
        _ = scheduler.enqueue(channel: 3, bytes(20))
        let order = (0..<20).compactMap { _ in scheduler.next(maxChunk: 1)?.channel }
        #expect(order == Array(repeating: 3, count: 20))
    }

    @Test func vtWithoutCreditDoesNotBlockALowChannel() {
        var scheduler = PhoneLinkScheduler(window: 0, bufferLimit: 1000)
        scheduler.open(channel: 2)
        scheduler.open(channel: 3, low: true)
        scheduler.grant(channel: 3, bytes: 10)
        _ = scheduler.enqueue(channel: 2, bytes(5))
        _ = scheduler.enqueue(channel: 3, bytes(5))
        #expect(scheduler.next(maxChunk: 10) == .data(channel: 3, bytes(5)))
        #expect(scheduler.next(maxChunk: 10) == nil)
    }

    @Test func overflowDropsOnlyThatChannel() {
        var scheduler = PhoneLinkScheduler(window: 100, bufferLimit: 8)
        scheduler.open(channel: 2)
        scheduler.open(channel: 3)
        #expect(scheduler.enqueue(channel: 3, bytes(4)) == .queued)
        #expect(scheduler.enqueue(channel: 0, bytes(4)) == .queued)
        #expect(scheduler.enqueue(channel: 2, bytes(9)) == .overflowed)
        #expect(scheduler.pendingBytes == 8)
        #expect(scheduler.next(maxChunk: 100)?.channel == 0)
        #expect(scheduler.next(maxChunk: 100)?.channel == 3)
        #expect(scheduler.next(maxChunk: 100) == nil)
    }

    @Test func overflowEmptiesQueuedBytes() {
        var scheduler = PhoneLinkScheduler(window: 100, bufferLimit: 8)
        scheduler.open(channel: 2)
        _ = scheduler.enqueue(channel: 2, bytes(6))
        #expect(scheduler.enqueue(channel: 2, bytes(3)) == .overflowed)
        #expect(scheduler.pendingBytes == 0)
    }

    @Test func grantClampsAtMax() {
        var scheduler = PhoneLinkScheduler(window: 2, bufferLimit: 100_000)
        scheduler.open(channel: 2)
        _ = scheduler.enqueue(channel: 2, bytes(70000))
        scheduler.grant(channel: 2, bytes: .max)
        scheduler.grant(channel: 2, bytes: .max)
        #expect(scheduler.next(maxChunk: 1 << 20)?.payload.count == PhoneLinkFrame.maxPayload)
    }

    @Test func grantAfterCloseDoesNotResurrectChannel() {
        var scheduler = PhoneLinkScheduler(window: 10, bufferLimit: 1000)
        scheduler.open(channel: 2)
        _ = scheduler.enqueue(channel: 2, bytes(1))
        scheduler.close(channel: 2)
        scheduler.grant(channel: 2, bytes: 100)
        scheduler.open(channel: 2)
        _ = scheduler.enqueue(channel: 2, bytes(60))
        #expect(scheduler.next(maxChunk: 1000)?.payload.count == 10)
    }

    @Test func enqueueAfterCloseIsRefused() {
        var scheduler = PhoneLinkScheduler(window: 10, bufferLimit: 1000)
        scheduler.open(channel: 2)
        scheduler.close(channel: 2)
        #expect(scheduler.enqueue(channel: 2, bytes(5)) == .closed)
        #expect(scheduler.enqueue(channel: 3, bytes(5)) == .closed)
        #expect(scheduler.next(maxChunk: 1000) == nil)
        #expect(scheduler.pendingBytes == 0)
    }

    @Test func creditBeforeFirstEnqueueIsKept() {
        var scheduler = PhoneLinkScheduler(window: 10, bufferLimit: 1000)
        scheduler.open(channel: 2)
        scheduler.grant(channel: 2, bytes: 5)
        _ = scheduler.enqueue(channel: 2, bytes(15))
        #expect(scheduler.next(maxChunk: 1000)?.payload.count == 15)
    }

    @Test func reopenResetsQueueAndCredit() {
        var scheduler = PhoneLinkScheduler(window: 10, bufferLimit: 1000)
        scheduler.open(channel: 2)
        _ = scheduler.enqueue(channel: 2, bytes(3))
        scheduler.grant(channel: 2, bytes: 100)
        scheduler.open(channel: 2)
        #expect(scheduler.pendingBytes == 0)
        _ = scheduler.enqueue(channel: 2, bytes(20))
        #expect(scheduler.next(maxChunk: 1000)?.payload.count == 10)
    }

    @Test func closeIgnoresControlChannels() {
        var scheduler = PhoneLinkScheduler(window: 10, bufferLimit: 1000)
        _ = scheduler.enqueue(channel: 0, bytes(2))
        _ = scheduler.enqueue(channel: 1, bytes(3))
        scheduler.close(channel: 0)
        scheduler.close(channel: 1)
        #expect(scheduler.pendingBytes == 5)
    }

    @Test func closingAtCursorKeepsRoundRobin() {
        var scheduler = PhoneLinkScheduler(window: 100, bufferLimit: 1000)
        for channel: UInt32 in 2...4 {
            scheduler.open(channel: channel)
            _ = scheduler.enqueue(channel: channel, bytes(4))
        }
        #expect(scheduler.next(maxChunk: 2)?.channel == 2)
        scheduler.close(channel: 3)
        let order = (0..<3).compactMap { _ in scheduler.next(maxChunk: 2)?.channel }
        #expect(order == [4, 2, 4])
    }

    @Test func closingBeforeCursorKeepsRoundRobin() {
        var scheduler = PhoneLinkScheduler(window: 100, bufferLimit: 1000)
        for channel: UInt32 in 2...4 {
            scheduler.open(channel: channel)
            _ = scheduler.enqueue(channel: channel, bytes(4))
        }
        #expect(scheduler.next(maxChunk: 2)?.channel == 2)
        #expect(scheduler.next(maxChunk: 2)?.channel == 3)
        scheduler.close(channel: 2)
        let order = (0..<3).compactMap { _ in scheduler.next(maxChunk: 2)?.channel }
        #expect(order == [4, 3, 4])
    }

    @Test func grantOnUnseenChannelIsIgnored() {
        var scheduler = PhoneLinkScheduler(window: 10, bufferLimit: 1000)
        scheduler.grant(channel: 7, bytes: 100)
        #expect(scheduler.next(maxChunk: 1000) == nil)
        #expect(scheduler.pendingBytes == 0)
    }

    @Test func closeDropsQueue() {
        var scheduler = PhoneLinkScheduler(window: 100, bufferLimit: 1000)
        scheduler.open(channel: 2)
        _ = scheduler.enqueue(channel: 2, bytes(5))
        scheduler.close(channel: 2)
        #expect(scheduler.pendingBytes == 0)
        #expect(scheduler.next(maxChunk: 10) == nil)
    }

    @Test func pendingBytesPerChannel() {
        var scheduler = PhoneLinkScheduler(window: 0, bufferLimit: 1000)
        scheduler.open(channel: 2)
        _ = scheduler.enqueue(channel: 1, bytes(7))
        _ = scheduler.enqueue(channel: 2, bytes(5))
        #expect(scheduler.pendingBytes(channel: 1) == 7)
        #expect(scheduler.pendingBytes(channel: 2) == 5)
        #expect(scheduler.pendingBytes(channel: 0) == 0)
        _ = scheduler.next(maxChunk: 3)
        #expect(scheduler.pendingBytes(channel: 1) == 4)
    }
}
