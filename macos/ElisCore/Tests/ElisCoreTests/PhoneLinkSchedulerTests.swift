import Foundation
import Testing
@testable import ElisCore

@Suite struct PhoneLinkSchedulerTests {
    private func bytes(_ count: Int, _ value: UInt8 = 1) -> Data { Data(repeating: value, count: count) }

    @Test func controlBeforeEventsBeforeOpened() {
        var scheduler = PhoneLinkScheduler(window: 100, bufferLimit: 1000)
        _ = scheduler.enqueue(channel: 2, bytes(1))
        _ = scheduler.enqueue(channel: 1, bytes(1))
        _ = scheduler.enqueue(channel: 0, bytes(1))
        #expect(scheduler.next(maxChunk: 10)?.channel == 0)
        #expect(scheduler.next(maxChunk: 10)?.channel == 1)
        #expect(scheduler.next(maxChunk: 10)?.channel == 2)
        #expect(scheduler.next(maxChunk: 10) == nil)
    }

    @Test func noCreditDoesNotBlockControl() {
        var scheduler = PhoneLinkScheduler(window: 0, bufferLimit: 1000)
        _ = scheduler.enqueue(channel: 2, bytes(5))
        _ = scheduler.enqueue(channel: 0, bytes(3))
        #expect(scheduler.next(maxChunk: 10) == .data(channel: 0, bytes(3)))
        #expect(scheduler.next(maxChunk: 10) == nil)
        #expect(scheduler.pendingBytes == 5)
    }

    @Test func chunkLimitedByCredit() {
        var scheduler = PhoneLinkScheduler(window: 10, bufferLimit: 1000)
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
        _ = scheduler.enqueue(channel: 2, bytes(4))
        _ = scheduler.enqueue(channel: 3, bytes(4))
        let order = (0..<4).compactMap { _ in scheduler.next(maxChunk: 2)?.channel }
        #expect(order == [2, 3, 2, 3])
        #expect(scheduler.next(maxChunk: 2) == nil)
    }

    @Test func overflowDropsOnlyThatChannel() {
        var scheduler = PhoneLinkScheduler(window: 100, bufferLimit: 8)
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
        _ = scheduler.enqueue(channel: 2, bytes(6))
        #expect(scheduler.enqueue(channel: 2, bytes(3)) == .overflowed)
        #expect(scheduler.pendingBytes == 0)
    }

    @Test func grantClampsAtMax() {
        var scheduler = PhoneLinkScheduler(window: 2, bufferLimit: 100_000)
        _ = scheduler.enqueue(channel: 2, bytes(70000))
        scheduler.grant(channel: 2, bytes: .max)
        scheduler.grant(channel: 2, bytes: .max)
        #expect(scheduler.next(maxChunk: 1 << 20)?.payload.count == PhoneLinkFrame.maxPayload)
    }

    @Test func grantAfterCloseDoesNotResurrectChannel() {
        var scheduler = PhoneLinkScheduler(window: 10, bufferLimit: 1000)
        _ = scheduler.enqueue(channel: 2, bytes(1))
        scheduler.close(channel: 2)
        scheduler.grant(channel: 2, bytes: 100)
        _ = scheduler.enqueue(channel: 2, bytes(60))
        #expect(scheduler.next(maxChunk: 1000)?.payload.count == 10)
    }

    @Test func grantOnUnseenChannelIsIgnored() {
        var scheduler = PhoneLinkScheduler(window: 10, bufferLimit: 1000)
        scheduler.grant(channel: 7, bytes: 100)
        #expect(scheduler.next(maxChunk: 1000) == nil)
        #expect(scheduler.pendingBytes == 0)
    }

    @Test func closeDropsQueue() {
        var scheduler = PhoneLinkScheduler(window: 100, bufferLimit: 1000)
        _ = scheduler.enqueue(channel: 2, bytes(5))
        scheduler.close(channel: 2)
        #expect(scheduler.pendingBytes == 0)
        #expect(scheduler.next(maxChunk: 10) == nil)
    }
}
