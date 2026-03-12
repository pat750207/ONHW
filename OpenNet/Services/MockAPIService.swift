//
//  MockAPIService.swift
//  OpenNet
//
//  Created by Pat Chang on 2026/3/10.
//

import Foundation

// 模擬 GET /matches 與 GET /odds 的記憶體資料來源（約 100 筆）。
final class MockAPIService: MatchAPIServiceProtocol {

    // static for reuse
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func fetchMatches() async throws -> [Match] {
        makeMatches()
    }

    func fetchOdds() async throws -> [Odds] {
        makeOdds()
    }

    private func makeMatches() -> [Match] {
        let teams = [
            "Eagles", "Tigers", "Lions", "Bears", "Wolves",
            "Hawks", "Sharks", "Storm", "Raptors", "Phoenix"
        ]
        let calendar = Calendar(identifier: .gregorian)
        var date = calendar.date(
            from: DateComponents(year: 2025, month: 7, day: 4, hour: 10, minute: 0)
        )!

        return (0..<100).map { i in
            let teamA = teams[i % teams.count]
            var teamB = teams[(i + 1) % teams.count]
            if teamA == teamB { teamB = teams[(i + 2) % teams.count] }

            let iso = Self.isoFormatter.string(from: date)
            let match = Match(matchID: 1001 + i, teamA: teamA, teamB: teamB, startTime: iso)
            date = calendar.date(byAdding: .minute, value: 30, to: date) ?? date
            return match
        }
    }

    private func makeOdds() -> [Odds] {
        (0..<100).map { i in
            Odds(
                matchID: 1001 + i,
                teamAOdds: Double.random(in: 1.05...10.2),
                teamBOdds: Double.random(in: 1.05...20.2)
            )
        }
    }
}
