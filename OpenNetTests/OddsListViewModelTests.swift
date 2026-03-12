//
//  OddsListViewModelTests.swift
//  OpenNetTests
//
// Created by Pat Chang on 2026/3/12.
//

import Combine
import XCTest
@testable import OpenNet

// APIService
private final class StubAPIService: MatchAPIServiceProtocol {
    var matchesToReturn: [Match] = []
    var oddsToReturn: [Odds] = []
    var shouldThrowError: APIError?

    func fetchMatches() async throws -> [Match] {
        if let error = shouldThrowError { throw error }
        return matchesToReturn
    }

    func fetchOdds() async throws -> [Odds] {
        if let error = shouldThrowError { throw error }
        return oddsToReturn
    }
}

// manual Service
private final class StubStreamService: OddsStreamProtocol {
    let updatesSubject = PassthroughSubject<[Odds], Never>()
    let disconnectedSubject = PassthroughSubject<Void, Never>()

    var updates: AnyPublisher<[Odds], Never> { updatesSubject.eraseToAnyPublisher() }
    var disconnected: AnyPublisher<Void, Never> { disconnectedSubject.eraseToAnyPublisher() }

    private(set) var isStarted = false
    private(set) var isPaused = false
    private(set) var reconnectCount = 0

    func start() { isStarted = true }
    func stop() { isStarted = false }
    func pause() { isPaused = true; stop() }
    func reconnect() { reconnectCount += 1; start() }
}

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

        // oddsStreamFactory 注入 Repository，ViewModel 只認識 Repository
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

    private func makeMatches(count: Int = 3) -> [Match] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let base = Date(timeIntervalSince1970: 1751641200)
        return (0..<count).map { i in
            Match(
                matchID: 1001 + i,
                teamA: "Team\(i)A",
                teamB: "Team\(i)B",
                startTime: formatter.string(from: base.addingTimeInterval(Double(i) * 1800))
            )
        }
    }

    private func makeOdds(count: Int = 3) -> [Odds] {
        (0..<count).map { i in
            Odds(matchID: 1001 + i, teamAOdds: 1.9, teamBOdds: 2.0)
        }
    }

    func testLoad_MergesAndSortsByStartTimeAscending() {
        let expectation = expectation(description: "list published")

        stubAPI.matchesToReturn = makeMatches(count: 5)
        stubAPI.oddsToReturn = makeOdds(count: 5)

        var receivedItems: [MatchCellModel] = []

        sut.listPublisher
            .dropFirst()  // 跳過初始空陣列
            .first()
            .sink { items in
                receivedItems = items
                expectation.fulfill()
            }
            .store(in: &cancellables)

        sut.load()

        waitForExpectations(timeout: 2)

        // 驗證數量
        XCTAssertEqual(receivedItems.count, 5, "應合併為 5 筆")

        // 驗證排序：startTime 應為升序
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        for i in 0..<(receivedItems.count - 1) {
            let t1 = formatter.date(from: receivedItems[i].startTime)!
            let t2 = formatter.date(from: receivedItems[i + 1].startTime)!
            XCTAssertLessThanOrEqual(t1, t2, "index \(i) 的時間應 <= index \(i+1)")
        }
    }

    func testLoad_WhenAPIFails_PublishesError() {
        let expectation = expectation(description: "error published")

        stubAPI.shouldThrowError = .networkFailed

        sut.errorPublisher
            .first()
            .sink { error in
                XCTAssertEqual(error, .networkFailed)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        sut.load()
        waitForExpectations(timeout: 2)
    }

    func testStreamUpdate_OnlyChangesOddsForMatchingID() {
        let loadExpectation = expectation(description: "initial load")
        let updateExpectation = expectation(description: "odds updated")

        stubAPI.matchesToReturn = makeMatches(count: 3)
        stubAPI.oddsToReturn = makeOdds(count: 3)

        var emissions: [[MatchCellModel]] = []

        sut.listPublisher
            .dropFirst()  // 跳過初始空陣列
            .sink { items in
                emissions.append(items)
                if emissions.count == 1 { loadExpectation.fulfill() }
                if emissions.count == 2 { updateExpectation.fulfill() }
            }
            .store(in: &cancellables)

        sut.load()
        wait(for: [loadExpectation], timeout: 2)

        // 初始載入完成後，才模擬推播更新 matchID=1002 的賠率
        // ViewModel 的 collect(.byTime 100ms) 會在約 100ms 內批次處理並推送
        let updatedOdds = Odds(matchID: 1002, teamAOdds: 5.5, teamBOdds: 6.6)
        stubStream.updatesSubject.send([updatedOdds])

        wait(for: [updateExpectation], timeout: 2)

        let latestItems = emissions.last!
        let updated = latestItems.first(where: { $0.matchID == 1002 })!
        XCTAssertEqual(updated.teamAOdds, 5.5, "matchID 1002 的 teamAOdds 應被更新")
        XCTAssertEqual(updated.teamBOdds, 6.6, "matchID 1002 的 teamBOdds 應被更新")

        // 其他比賽賠率不應改變
        let unchanged = latestItems.first(where: { $0.matchID == 1001 })!
        XCTAssertEqual(unchanged.teamAOdds, 1.9, "matchID 1001 的賠率不應被改變")
    }

    func testMergedItems_AllFieldsPopulated() {
        let expectation = expectation(description: "list published")

        stubAPI.matchesToReturn = makeMatches(count: 3)
        stubAPI.oddsToReturn = makeOdds(count: 3)

        sut.listPublisher
            .dropFirst()
            .first()
            .sink { items in
                for item in items {
                    XCTAssertGreaterThan(item.matchID, 0)
                    XCTAssertFalse(item.teamA.isEmpty)
                    XCTAssertFalse(item.teamB.isEmpty)
                    XCTAssertFalse(item.startTime.isEmpty)
                    XCTAssertGreaterThan(item.teamAOdds, 0)
                    XCTAssertGreaterThan(item.teamBOdds, 0)
                }
                expectation.fulfill()
            }
            .store(in: &cancellables)

        sut.load()
        waitForExpectations(timeout: 2)
    }

    func testPauseStream_DelegatesToRepository() {
        // 先 load 啟動 stream
        stubAPI.matchesToReturn = makeMatches(count: 1)
        stubAPI.oddsToReturn = makeOdds(count: 1)

        let exp = expectation(description: "loaded")
        sut.listPublisher.dropFirst().first().sink { _ in exp.fulfill() }.store(in: &cancellables)
        sut.load()
        waitForExpectations(timeout: 2)

        sut.pauseStream()
        XCTAssertTrue(stubStream.isPaused, "應透過 Repository 轉發 pause 給 stream")
    }

    func testReconnectStream_DelegatesToRepository() {
        stubAPI.matchesToReturn = makeMatches(count: 1)
        stubAPI.oddsToReturn = makeOdds(count: 1)

        let exp = expectation(description: "loaded")
        sut.listPublisher.dropFirst().first().sink { _ in exp.fulfill() }.store(in: &cancellables)
        sut.load()
        waitForExpectations(timeout: 2)

        sut.reconnectStream()
        XCTAssertEqual(stubStream.reconnectCount, 1, "應透過 Repository 轉發 reconnect 給 stream")
    }

}
