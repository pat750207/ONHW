//
//  MatchAPIServiceProtocol.swift
//  OpenNet
//
//  Created by Pat Chang on 2026/3/10.
//

import Foundation

// REST API error。
enum APIError: Error, Equatable {
    case networkFailed
    case decodingFailed
    case serverError(Int)
}

// for test and viewmodel inject
protocol MatchAPIServiceProtocol: AnyObject {
    func fetchMatches() async throws -> [Match]
    func fetchOdds() async throws -> [Odds]
}
