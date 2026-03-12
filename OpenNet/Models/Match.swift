//
//  Match.swift
//  OpenNet
//
//  Created by Pat Chang on 2026/3/10.
//

import Foundation

/// GET /matches 回傳的單場比賽資料。
struct Match: Codable, Equatable, Sendable {
  let matchID: Int
  let teamA: String
  let teamB: String
  let startTime: String  // ISO 8601，例如 "2025-07-04T13:00:00Z"
}
