//
//  TestStubs.swift
//  OpenNetTests
//

import Combine
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

final class StubStreamService: OddsStreamProtocol {
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
