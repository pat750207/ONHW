//
//  MatchAPIServiceProtocol.swift
//  OpenNet
//
//  Created by Pat Chang on 2026/3/10.
//

import Foundation

// REST API error。
enum APIError: Error, Equatable, Sendable {
    case networkFailed
    case decodingFailed
    case serverError(Int)
}

// AnyObject 移除：MockAPIService 為 struct，不強制 reference type。
protocol MatchAPIServiceProtocol {
    func fetchMatches() async throws -> [Match]
    func fetchOdds() async throws -> [Odds]
}
