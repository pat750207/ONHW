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

// OddsStreamProtocol：updates / disconnected 為 get async，生命週期方法為 async。
// final class 搭配 @unchecked Sendable 僅供測試單線程使用。
final class StubStreamService: OddsStreamProtocol, @unchecked Sendable {

    private let updatesStream: AsyncStream<[Odds]>
    private let disconnectedStream: AsyncStream<Void>

    private(set) var updatesContinuation: AsyncStream<[Odds]>.Continuation?
    private(set) var disconnectedContinuation: AsyncStream<Void>.Continuation?

    var updates: AsyncStream<[Odds]> {
        get async { updatesStream }
    }

    var disconnected: AsyncStream<Void> {
        get async { disconnectedStream }
    }

    private(set) var isStarted = false
    private(set) var isPaused = false
    private(set) var reconnectCount = 0

    init() {
        var updatesCont: AsyncStream<[Odds]>.Continuation!
        var disconnectedCont: AsyncStream<Void>.Continuation!
        updatesStream = AsyncStream { updatesCont = $0 }
        disconnectedStream = AsyncStream { disconnectedCont = $0 }
        updatesContinuation = updatesCont
        disconnectedContinuation = disconnectedCont
    }

    func start() async {
        isStarted = true
    }

    func stop() async {
        isStarted = false
    }

    func pause() async {
        isPaused = true
        await stop()
    }

    func reconnect() async {
        reconnectCount += 1
        await start()
    }

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
