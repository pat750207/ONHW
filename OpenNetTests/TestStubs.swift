//
//  TestStubs.swift
//  OpenNetTests
//

import Foundation
@testable import OpenNet

// MARK: - API Stub

final class StubAPIService: MatchAPIServiceProtocol {
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

// MARK: - Stream Stub

// OddsStreamProtocol: Sendable，final class 無法自動合規，用 @unchecked 手動宣告。
// 測試環境單線程使用，不存在真實 data race。
//
// Continuation 存為 private(set) var，測試透過 sendOddsUpdate / sendDisconnect
// 方法模擬推播，比 PassthroughSubject 更貼近 AsyncStream 的實際使用方式。
final class StubStreamService: OddsStreamProtocol, @unchecked Sendable {

    private(set) var updatesContinuation: AsyncStream<[Odds]>.Continuation?
    private(set) var disconnectedContinuation: AsyncStream<Void>.Continuation?

    let updates: AsyncStream<[Odds]>
    let disconnected: AsyncStream<Void>

    private(set) var isStarted = false
    private(set) var isPaused = false
    private(set) var reconnectCount = 0

    init() {
        var updatesCont: AsyncStream<[Odds]>.Continuation!
        var disconnectedCont: AsyncStream<Void>.Continuation!
        updates = AsyncStream { updatesCont = $0 }
        disconnected = AsyncStream { disconnectedCont = $0 }
        updatesContinuation = updatesCont
        disconnectedContinuation = disconnectedCont
    }

    func start() { isStarted = true }
    func stop() { isStarted = false }
    func pause() { isPaused = true; stop() }
    func reconnect() { reconnectCount += 1; start() }

    // MARK: - Test Helpers

    func sendOddsUpdate(_ odds: [Odds]) { updatesContinuation?.yield(odds) }
    func sendDisconnect() { disconnectedContinuation?.yield(()) }
}

// MARK: - Fixtures

enum TestFixtures {
    static func makeMatches(count: Int = 3, startingID: Int = 1001) -> [Match] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let base = Date(timeIntervalSince1970: 1751641200)
        return (0..<count).map { i in
            Match(
                matchID: startingID + i,
                teamA: "Team\(i)A",
                teamB: "Team\(i)B",
                startTime: formatter.string(from: base.addingTimeInterval(Double(i) * 1800))
            )
        }
    }

    static func makeOdds(
        count: Int = 3,
        startingID: Int = 1001,
        teamAOdds: Double = 1.9,
        teamBOdds: Double = 2.0
    ) -> [Odds] {
        (0..<count).map { i in
            Odds(matchID: startingID + i, teamAOdds: teamAOdds, teamBOdds: teamBOdds)
        }
    }
}
