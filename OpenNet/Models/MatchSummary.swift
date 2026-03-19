//
//  MatchSummary.swift
//  OpenNet
//
//  Created by Pat Chang on 2026/3/10.
//

import Foundation


struct MatchSummary: Identifiable, Sendable {

  let matchID: Int
  let teamA: String
  let teamB: String
  let startTime: Date
  let teamAOdds: Double
  let teamBOdds: Double

  var id: Int { matchID }

  /// 判斷同一場比賽的賠率是否有變動，用於決定是否需要 reconfigure cell。
  static func oddsChanged(_ a: MatchSummary, _ b: MatchSummary) -> Bool {
    a.matchID == b.matchID
      && (a.teamAOdds != b.teamAOdds || a.teamBOdds != b.teamBOdds)
  }
}
