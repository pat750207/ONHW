//
//  OddsRepositoryTests.swift
//  OpenNetTests
//

import XCTest
@testable import OpenNet

final class OddsRepositoryTests: XCTestCase {

    private var stubAPI: StubAPIService!
    private var repository: OddsRepository!

    override func setUp() {
        super.setUp()
        stubAPI = StubAPIService()
        repository = OddsRepository(
            apiService: stubAPI,
            oddsStreamFactory: { _ in StubStreamService() }
        )
    }

    override func tearDown() {
        repository = nil
        stubAPI = nil
        super.tearDown()
    }

    // MARK: - fetchSnapshot

    func testFetchSnapshot_MergesAndSortsByStartTimeAscending() async throws {
        stubAPI.matchesToReturn = TestFixtures.makeMatches(count: 5)
        stubAPI.oddsToReturn = TestFixtures.makeOdds(count: 5)

        let cells = try await repository.fetchSnapshot()

        XCTAssertEqual(cells.count, 5)
        for i in 0..<(cells.count - 1) {
            XCTAssertLessThanOrEqual(
                cells[i].startTime, cells[i + 1].startTime,
                "index \(i) 應早於 index \(i+1)"
            )
        }
    }

    func testFetchSnapshot_UpdatesCache() async throws {
        stubAPI.matchesToReturn = TestFixtures.makeMatches(count: 3)
        stubAPI.oddsToReturn = TestFixtures.makeOdds(count: 3)

        _ = try await repository.fetchSnapshot()

        let cached = await repository.cachedList
        XCTAssertEqual(cached.count, 3, "fetchSnapshot 後 cachedList 應有 3 筆")
    }

    func testFetchSnapshot_WhenAPIFails_Throws() async {
        stubAPI.shouldThrowError = .networkFailed

        do {
            _ = try await repository.fetchSnapshot()
            XCTFail("應 throw 但沒有")
        } catch {
            XCTAssertEqual(error as? APIError, .networkFailed)
        }
    }

    func testFetchSnapshot_SkipsMatchesWithoutOdds() async throws {
        stubAPI.matchesToReturn = TestFixtures.makeMatches(count: 3) // IDs: 1001, 1002, 1003
        stubAPI.oddsToReturn = TestFixtures.makeOdds(count: 2)       // IDs: 1001, 1002

        let cells = try await repository.fetchSnapshot()

        XCTAssertEqual(cells.count, 2, "沒有對應賠率的比賽不應出現")
        XCTAssertFalse(cells.contains(where: { $0.matchID == 1003 }))
    }

    // MARK: - applyUpdates highlight detection

    func testApplyUpdates_TeamAChanged_ReturnsTeamASide() async throws {
        stubAPI.matchesToReturn = TestFixtures.makeMatches(count: 1)
        stubAPI.oddsToReturn = TestFixtures.makeOdds(count: 1, teamAOdds: 1.9, teamBOdds: 2.0)
        _ = try await repository.fetchSnapshot()

        let update = Odds(matchID: 1001, teamAOdds: 2.5, teamBOdds: 2.0)
        let result = await repository.applyUpdates([update])

        XCTAssertEqual(result.changes[1001], .teamA)
        XCTAssertEqual(result.list.first?.teamAOdds, 2.5)
        XCTAssertEqual(result.list.first?.teamBOdds, 2.0)
    }

    func testApplyUpdates_TeamBChanged_ReturnsTeamBSide() async throws {
        stubAPI.matchesToReturn = TestFixtures.makeMatches(count: 1)
        stubAPI.oddsToReturn = TestFixtures.makeOdds(count: 1, teamAOdds: 1.9, teamBOdds: 2.0)
        _ = try await repository.fetchSnapshot()

        let update = Odds(matchID: 1001, teamAOdds: 1.9, teamBOdds: 3.5)
        let result = await repository.applyUpdates([update])

        XCTAssertEqual(result.changes[1001], .teamB)
        XCTAssertEqual(result.list.first?.teamBOdds, 3.5)
    }

    func testApplyUpdates_BothChanged_ReturnsBothSide() async throws {
        stubAPI.matchesToReturn = TestFixtures.makeMatches(count: 1)
        stubAPI.oddsToReturn = TestFixtures.makeOdds(count: 1, teamAOdds: 1.9, teamBOdds: 2.0)
        _ = try await repository.fetchSnapshot()

        let update = Odds(matchID: 1001, teamAOdds: 2.5, teamBOdds: 3.5)
        let result = await repository.applyUpdates([update])

        XCTAssertEqual(result.changes[1001], .both)
    }

    func testApplyUpdates_NoOddsChange_ReturnsEmptyChanges() async throws {
        stubAPI.matchesToReturn = TestFixtures.makeMatches(count: 1)
        stubAPI.oddsToReturn = TestFixtures.makeOdds(count: 1, teamAOdds: 1.9, teamBOdds: 2.0)
        _ = try await repository.fetchSnapshot()

        let update = Odds(matchID: 1001, teamAOdds: 1.9, teamBOdds: 2.0)
        let result = await repository.applyUpdates([update])

        XCTAssertTrue(result.changes.isEmpty, "賠率未改變時不應產生 highlight")
    }

    func testApplyUpdates_UnknownMatchID_IsIgnored() async throws {
        stubAPI.matchesToReturn = TestFixtures.makeMatches(count: 1)
        stubAPI.oddsToReturn = TestFixtures.makeOdds(count: 1)
        _ = try await repository.fetchSnapshot()

        let update = Odds(matchID: 9999, teamAOdds: 5.0, teamBOdds: 6.0)
        let result = await repository.applyUpdates([update])

        XCTAssertTrue(result.changes.isEmpty)
        XCTAssertEqual(result.list.count, 1, "list 長度不應改變")
    }

    func testApplyUpdates_EmptyUpdates_ReturnsCachedList() async throws {
        stubAPI.matchesToReturn = TestFixtures.makeMatches(count: 2)
        stubAPI.oddsToReturn = TestFixtures.makeOdds(count: 2)
        _ = try await repository.fetchSnapshot()

        let result = await repository.applyUpdates([])

        XCTAssertTrue(result.changes.isEmpty)
        XCTAssertEqual(result.list.count, 2)
    }
}
