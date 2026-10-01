import Contacts
import XCTest
@testable import ContactsChangeNotifier

/// The forward step runs against a stubbed fetch: these tests never touch a
/// real `CNContactStore`.
final class ChangeHistoryForwardStepTests: XCTestCase {

    private final class MemoryTokenStorage: HistoryTokenStorage, @unchecked Sendable {
        var tokenData: Data?
        init(_ tokenData: Data?) { self.tokenData = tokenData }
    }

    private struct FetchFailed: Error {}

    private let tokenA = Data("A".utf8)
    private let tokenB = Data("B".utf8)
    private let tokenC = Data("C".utf8)

    func testFetchesFromTheStoredTokenAndStoresTheFetchsOwnToken() throws {
        let storage = MemoryTokenStorage(tokenA)
        let event = CNChangeHistoryEvent()
        var startingTokens: [Data?] = []

        let events = try ChangeHistoryForwardStep.run(tokenStorage: storage) { startingToken in
            startingTokens.append(startingToken)
            return (events: [event], token: self.tokenB)
        }

        XCTAssertEqual(startingTokens, [tokenA])
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events.first === event)
        XCTAssertEqual(storage.tokenData, tokenB)
    }

    func testEmptyHistoryStillAdvancesTheToken() throws {
        let storage = MemoryTokenStorage(tokenA)

        let events = try ChangeHistoryForwardStep.run(tokenStorage: storage) { _ in
            (events: [], token: self.tokenB)
        }

        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(storage.tokenData, tokenB)
    }

    func testDropEverythingIsForwardedAndTheTokenAdvances() throws {
        let storage = MemoryTokenStorage(tokenA)
        let drop = CNChangeHistoryDropEverythingEvent()
        let after = CNChangeHistoryEvent()

        let events = try ChangeHistoryForwardStep.run(tokenStorage: storage) { _ in
            (events: [drop, after], token: self.tokenB)
        }

        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events[0] is CNChangeHistoryDropEverythingEvent)
        XCTAssertTrue(events[1] === after)
        XCTAssertEqual(storage.tokenData, tokenB)
    }

    func testAFailedFetchLeavesTheTokenWhereItWas() {
        let storage = MemoryTokenStorage(tokenA)

        XCTAssertThrowsError(try ChangeHistoryForwardStep.run(tokenStorage: storage) { _ in
            throw FetchFailed()
        })

        XCTAssertEqual(storage.tokenData, tokenA)
    }

    /// One external save posts `CNContactStoreDidChange` many times. Run in
    /// sequence (the serial forward queue), only the first forward of the
    /// burst returns the change; the rest start from the advanced token.
    func testANotificationBurstForwardsTheChangeOnce() throws {
        let storage = MemoryTokenStorage(tokenA)
        let change = CNChangeHistoryEvent()
        // The store's history: one change after A, nothing after B.
        let history: [Data: (events: [CNChangeHistoryEvent], token: Data)] = [
            tokenA: (events: [change], token: tokenB),
            tokenB: (events: [], token: tokenB),
        ]

        var forwarded: [[CNChangeHistoryEvent]] = []
        for _ in 0..<5 {
            let events = try ChangeHistoryForwardStep.run(tokenStorage: storage) { startingToken in
                try XCTUnwrap(history[try XCTUnwrap(startingToken)])
            }
            if !events.isEmpty { forwarded.append(events) }
        }

        XCTAssertEqual(forwarded.count, 1)
        XCTAssertTrue(forwarded.first?.first === change)
        XCTAssertEqual(storage.tokenData, tokenB)
    }

    /// A change landing after the fetch must stay ahead of the stored token.
    /// The fetch's own token (B) is stored even though the store has since
    /// moved on (C), so the next forward still picks the change up.
    func testAChangeAfterTheFetchIsPickedUpByTheNextForward() throws {
        let storage = MemoryTokenStorage(tokenA)
        let late = CNChangeHistoryEvent()

        _ = try ChangeHistoryForwardStep.run(tokenStorage: storage) { _ in
            (events: [], token: self.tokenB)
        }
        let next = try ChangeHistoryForwardStep.run(tokenStorage: storage) { startingToken in
            XCTAssertEqual(startingToken, self.tokenB)
            return (events: [late], token: self.tokenC)
        }

        XCTAssertTrue(next.first === late)
        XCTAssertEqual(storage.tokenData, tokenC)
    }

    /// The write-layer seam: an app that saves to Contacts passes its own
    /// transaction author here, alongside the bundle id default.
    func testFetchRequestTakesExtraExcludedTransactionAuthors() {
        let bundleDefault = CNChangeHistoryFetchRequest.fetchRequest()
        XCTAssertEqual(bundleDefault.excludedTransactionAuthors, Bundle.main.bundleIdentifier.map { [$0] })

        let withWriter = CNChangeHistoryFetchRequest.fetchRequest(
            excludedTransactionAuthors: ["com.example.app", "com.example.app.contacts-writer"]
        )
        XCTAssertEqual(withWriter.excludedTransactionAuthors, ["com.example.app", "com.example.app.contacts-writer"])
    }
}
