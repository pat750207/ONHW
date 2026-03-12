//
//  Odds.swift
//  OpenNet
//
//  Created by Pat Chang on 2026/3/10.
//

import Foundation

// GET /odds 與 WebSocket 推播共用的賠率資料結構。
// 推播時僅更新賠率（teamAOdds / teamBOdds），比賽時間不變
struct Odds: Codable, Equatable, Sendable {
  let matchID: Int
  let teamAOdds: Double
  let teamBOdds: Double
}
