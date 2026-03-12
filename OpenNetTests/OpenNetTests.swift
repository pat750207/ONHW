//
//  OpenNetTests.swift
//  OpenNetTests
//
//  Created by Pat Chang on 2026/3/12.
//

import XCTest
@testable import OpenNet

// test model
final class OpenNetModelTests: XCTestCase {

    func testMatch_Equatable() {
        let a = Match(matchID: 1001, teamA: "Eagles", teamB: "Tigers", startTime: "2025-07-04T13:00:00Z")
        let b = Match(matchID: 1001, teamA: "Eagles", teamB: "Tigers", startTime: "2025-07-04T13:00:00Z")
        XCTAssertEqual(a, b)
    }

    func testMatch_Codable_RoundTrip() throws {
        let original = Match(matchID: 1001, teamA: "Eagles", teamB: "Tigers", startTime: "2025-07-04T13:00:00Z")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Match.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testOdds_Equatable() {
        let a = Odds(matchID: 1001, teamAOdds: 1.95, teamBOdds: 2.10)
        let b = Odds(matchID: 1001, teamAOdds: 1.95, teamBOdds: 2.10)
        XCTAssertEqual(a, b)
    }

    func testOdds_Codable_RoundTrip() throws {
        let original = Odds(matchID: 1001, teamAOdds: 1.95, teamBOdds: 2.10)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Odds.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testOdds_DecodesFromJSON() throws {
        let json = """
        {"matchID": 1001, "teamAOdds": 1.92, "teamBOdds": 2.08}
        """.data(using: .utf8)!
        let odds = try JSONDecoder().decode(Odds.self, from: json)
        XCTAssertEqual(odds.matchID, 1001)
        XCTAssertEqual(odds.teamAOdds, 1.92)
        XCTAssertEqual(odds.teamBOdds, 2.08)
    }
}
