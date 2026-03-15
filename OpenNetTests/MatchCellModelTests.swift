//
//  MatchCellModelTests.swift
//  OpenNetTests
//
//  Created by Pat Chang on 2026/3/12.
//

import XCTest
@testable import OpenNet

final class MatchCellModelTests: XCTestCase {

    func testIdentifiable_IDIsMatchID() {
        let item = makeItem(matchID: 42, teamAOdds: 1.5, teamBOdds: 2.5)
        XCTAssertEqual(item.id, 42)
    }

    func testOddsChanged_WhenBothDiffer_ReturnsTrue() {
        let a = makeItem(matchID: 1001, teamAOdds: 1.9, teamBOdds: 2.0)
        let b = makeItem(matchID: 1001, teamAOdds: 1.92, teamBOdds: 2.08)
        XCTAssertTrue(MatchCellModel.oddsChanged(a, b))
    }

    func testOddsChanged_WhenOnlyTeamAOddsDiffer_ReturnsTrue() {
        let a = makeItem(matchID: 1001, teamAOdds: 1.9, teamBOdds: 2.0)
        let b = makeItem(matchID: 1001, teamAOdds: 2.5, teamBOdds: 2.0)
        XCTAssertTrue(MatchCellModel.oddsChanged(a, b))
    }

    func testOddsChanged_WhenOnlyTeamBOddsDiffer_ReturnsTrue() {
        let a = makeItem(matchID: 1001, teamAOdds: 1.9, teamBOdds: 2.0)
        let b = makeItem(matchID: 1001, teamAOdds: 1.9, teamBOdds: 3.5)
        XCTAssertTrue(MatchCellModel.oddsChanged(a, b))
    }

    func testOddsChanged_WhenOddsSame_ReturnsFalse() {
        let a = makeItem(matchID: 1001, teamAOdds: 1.9, teamBOdds: 2.0)
        let b = makeItem(matchID: 1001, teamAOdds: 1.9, teamBOdds: 2.0)
        XCTAssertFalse(MatchCellModel.oddsChanged(a, b))
    }

    func testOddsChanged_DifferentMatchID_ReturnsFalse() {
        let a = makeItem(matchID: 1001, teamAOdds: 1.9, teamBOdds: 2.0)
        let b = makeItem(matchID: 1002, teamAOdds: 1.95, teamBOdds: 2.05)
        XCTAssertFalse(MatchCellModel.oddsChanged(a, b))
    }

    private func makeItem(matchID: Int, teamAOdds: Double, teamBOdds: Double) -> MatchCellModel {
        MatchCellModel(
            matchID: matchID,
            teamA: "TeamA",
            teamB: "TeamB",
            startTime: Date(timeIntervalSince1970: 1751641200),
            teamAOdds: teamAOdds,
            teamBOdds: teamBOdds
        )
    }
}
