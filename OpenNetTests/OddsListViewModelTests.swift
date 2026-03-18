//
//  OddsListViewModelTests.swift
//  OpenNetTests
//
// Created by Pat Chang on 2026/3/12.
//

import Combine
import XCTest
@testable import OpenNet

final class OddsListViewModelTests: XCTestCase {

    private var stubAPI: StubAPIService!
    private var stubStream: StubStreamService!
    private var repository: OddsRepository!
    private var sut: OddsListViewModel!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        stubAPI = StubAPIService()
        stubStream = StubStreamService()
        cancellables = []

        repository = OddsRepository(
            apiService: stubAPI,
            oddsStreamFactory: { [weak self] _ in self?.stubStream ?? StubStreamService() }
        )
        sut = OddsListViewModel(repository: repository)
    }

    override func tearDown() {
        cancellables = nil
        sut = nil
        repository = nil
        stubStream = nil
        stubAPI = nil
        super.tearDown()
    }

    // MARK: - load

    func testLoad_MergesAndSortsByStartTimeAscending() async throws {
        stubAPI.matchesToReturn = TestFixtures.makeMatches(count: 5)
        stubAPI.oddsToReturn = TestFixtures.makeOdds(count: 5)

        let exp = expectation(description: "list published")
        var receivedItems: [MatchCellModel] = []

        sut.listPublisher
            .dropFirst()
            .first()
            .sink { items in
                receivedItems = items
                exp.fulfill()
            }
            .store(in: &cancellables)

        sut.load()
        await fulfillment(of: [exp], timeout: 2)

        XCTAssertEqual(receivedItems.count, 5, "應合併為 5 筆")
        for i in 0..<(receivedItems.count - 1) {
            XCTAssertLessThanOrEqual(
                receivedItems[i].startTime,
                receivedItems[i + 1].startTime,
                "index \(i) 的時間應 <= index \(i+1)"
            )
        }
    }

    func testLoad_WhenAPIFails_PublishesError() async throws {
        stubAPI.shouldThrowError = .networkFailed

        let exp = expectation(description: "error published")
        sut.errorPublisher
            .first()
            .sink { error in
                XCTAssertEqual(error, .networkFailed)
                exp.fulfill()
            }
            .store(in: &cancellables)

        sut.load()
        await fulfillment(of: [exp], timeout: 2)
    }

    func testLoad_CalledTwice_DoesNotDuplicateStream() async throws {
        stubAPI.matchesToReturn = TestFixtures.makeMatches(count: 1)
        stubAPI.oddsToReturn = TestFixtures.makeOdds(count: 1)

        let exp = expectation(description: "loaded")
        exp.expectedFulfillmentCount = 1

        sut.listPublisher
            .dropFirst()
            .first()
            .sink { _ in exp.fulfill() }
            .store(in: &cancellables)

        // 快速呼叫兩次，第一次應被取消
        sut.load()
        sut.load()

        await fulfillment(of: [exp], timeout: 2)
        // 最終只有一次有效 stream 訂閱
        XCTAssertTrue(stubStream.isStarted)
    }

    // MARK: - stream updates

    func testStreamUpdate_OnlyChangesOddsForMatchingID() async throws {
        stubAPI.matchesToReturn = TestFixtures.makeMatches(count: 3)
        stubAPI.oddsToReturn = TestFixtures.makeOdds(count: 3)

        let loadExp = expectation(description: "initial load")
        let updateExp = expectation(description: "odds updated")
        var emissions: [[MatchCellModel]] = []

        sut.listPublisher
            .dropFirst()
            .sink { items in
                emissions.append(items)
                if emissions.count == 1 { loadExp.fulfill() }
                if emissions.count == 2 { updateExp.fulfill() }
            }
            .store(in: &cancellables)

        sut.load()
        await fulfillment(of: [loadExp], timeout: 2)

        let updatedOdds = Odds(matchID: 1002, teamAOdds: 5.5, teamBOdds: 6.6)
        stubStream.sendOddsUpdate([updatedOdds])

        await fulfillment(of: [updateExp], timeout: 2)

        let latestItems = emissions.last!
        let updated = latestItems.first(where: { $0.matchID == 1002 })!
        XCTAssertEqual(updated.teamAOdds, 5.5, "matchID 1002 的 teamAOdds 應被更新")
        XCTAssertEqual(updated.teamBOdds, 6.6, "matchID 1002 的 teamBOdds 應被更新")

        let unchanged = latestItems.first(where: { $0.matchID == 1001 })!
        XCTAssertEqual(unchanged.teamAOdds, 1.9, "matchID 1001 的賠率不應被改變")
    }

    func testChangesPublisher_WhenOddsUpdate_PublishesHighlightSide() async throws {
        stubAPI.matchesToReturn = TestFixtures.makeMatches(count: 2)
        stubAPI.oddsToReturn = TestFixtures.makeOdds(count: 2, teamAOdds: 1.9, teamBOdds: 2.0)

        let loadExp = expectation(description: "initial load")
        let changesExp = expectation(description: "changes published")
        var receivedChanges: [Int: OddsHighlightSide] = [:]

        sut.listPublisher.dropFirst().first().sink { _ in loadExp.fulfill() }.store(in: &cancellables)
        sut.changesPublisher
            .first()
            .sink { changes in
                receivedChanges = changes
                changesExp.fulfill()
            }
            .store(in: &cancellables)

        sut.load()
        await fulfillment(of: [loadExp], timeout: 2)

        // teamA 改變 → should be .teamA
        stubStream.sendOddsUpdate([Odds(matchID: 1001, teamAOdds: 3.0, teamBOdds: 2.0)])

        await fulfillment(of: [changesExp], timeout: 2)
        XCTAssertEqual(receivedChanges[1001], .teamA)
    }

    // MARK: - all fields populated

    func testMergedItems_AllFieldsPopulated() async throws {
        stubAPI.matchesToReturn = TestFixtures.makeMatches(count: 3)
        stubAPI.oddsToReturn = TestFixtures.makeOdds(count: 3)

        let exp = expectation(description: "list published")
        sut.listPublisher
            .dropFirst()
            .first()
            .sink { items in
                for item in items {
                    XCTAssertGreaterThan(item.matchID, 0)
                    XCTAssertFalse(item.teamA.isEmpty)
                    XCTAssertFalse(item.teamB.isEmpty)
                    XCTAssertNotEqual(item.startTime, .distantPast, "startTime 應被正確解析")
                    XCTAssertGreaterThan(item.teamAOdds, 0)
                    XCTAssertGreaterThan(item.teamBOdds, 0)
                }
                exp.fulfill()
            }
            .store(in: &cancellables)

        sut.load()
        await fulfillment(of: [exp], timeout: 2)
    }

    // MARK: - lifecycle delegation

    func testPauseStream_DelegatesToRepository() async throws {
        stubAPI.matchesToReturn = TestFixtures.makeMatches(count: 1)
        stubAPI.oddsToReturn = TestFixtures.makeOdds(count: 1)

        let exp = expectation(description: "loaded")
        sut.listPublisher.dropFirst().first().sink { _ in exp.fulfill() }.store(in: &cancellables)
        sut.load()
        await fulfillment(of: [exp], timeout: 2)

        await sut.pauseStream()
        XCTAssertTrue(stubStream.isPaused, "應透過 Repository 轉發 pause 給 stream")
    }

    func testReconnectStream_DelegatesToRepository() async throws {
        stubAPI.matchesToReturn = TestFixtures.makeMatches(count: 1)
        stubAPI.oddsToReturn = TestFixtures.makeOdds(count: 1)

        let exp = expectation(description: "loaded")
        sut.listPublisher.dropFirst().first().sink { _ in exp.fulfill() }.store(in: &cancellables)
        sut.load()
        await fulfillment(of: [exp], timeout: 2)

        await sut.reconnectStream()
        XCTAssertEqual(stubStream.reconnectCount, 1, "應透過 Repository 轉發 reconnect 給 stream")
    }
}
