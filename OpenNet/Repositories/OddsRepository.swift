//
//  OddsRepository.swift
//  OpenNet
//
//  Created by Pat Chang on 2026/3/12.
//

import Foundation

// Repository Pattern
// 所有資料的唯一窗口：REST、WebSocket、cache、applyUpdates
//
// 分層原則：
// - Service 層回傳 AsyncStream（Sendable value type，thread-safe）
// - Repository 管理 stream 生命週期，對外暴露 activeStream
// - ViewModel（@MainActor）透過 activeStream 取得 AsyncStream，
//   在 MainActor context 上 await stream.updates / stream.disconnected
//
// ## 為何不在 Repository 存 AsyncStream 屬性
// AsyncStream 在此 SDK 版本帶有 @MainActor 推斷；
// 若存入 actor OddsRepository 的 stored property，
// OddsRepository（非 MainActor）的方法讀寫時會違反 isolation。
// 改由 @MainActor ViewModel 自行 await 存取，類型和 isolation 均合法。
actor OddsRepository {

    // any MatchAPIServiceProtocol：移除 AnyObject 後改用 Swift 5.7 existential 語法。
    private let apiService: any MatchAPIServiceProtocol

    // async factory：OddsStreamService.init 被 SDK 推斷為 @MainActor，
    // 需用 `await MainActor.run { }` 建立，factory 本身必須宣告 async。
    private let oddsStreamFactory: ([Int]) async -> any OddsStreamProtocol

    // 持有 stream service 實例，用於生命週期管理（start / pause / reconnect）
    private var oddsStream: (any OddsStreamProtocol)?

    private(set) var cachedList: [MatchCellModel] = []

    // @MainActor ViewModel 透過此屬性取得 stream service，
    // 再於 MainActor context 自行 await stream.updates / stream.disconnected。
    var activeStream: (any OddsStreamProtocol)? { oddsStream }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init(
        apiService: any MatchAPIServiceProtocol,
        oddsStreamFactory: @escaping ([Int]) async -> any OddsStreamProtocol = { matchIDs in
            await MainActor.run { OddsStreamService(matchIDs: matchIDs) }
        }
    ) {
        self.apiService = apiService
        self.oddsStreamFactory = oddsStreamFactory
    }

    func startStream(for matchIDs: [Int]) async {
        let stream = await oddsStreamFactory(matchIDs)
        self.oddsStream = stream
        await stream.start()
    }

    func pauseStream() async {
        print("[Repository] 暫停串流")
        await oddsStream?.pause()
    }

    func reconnectStream() async {
        print("[Repository] 觸發重連")
        await oddsStream?.reconnect()
    }

    // get matches + odds，合併、排序，更新快取後回傳結果。
    func fetchSnapshot() async throws -> [MatchCellModel] {
        async let matches = apiService.fetchMatches()
        async let odds = apiService.fetchOdds()
        let (m, o) = try await (matches, odds)
        let cells = sort(merge(matches: m, odds: o))
        cachedList = cells
        return cells
    }

    // for highlight
    typealias UpdateResult = (list: [MatchCellModel], changes: [Int: OddsHighlightSide])

    // returns list and highlight
    func applyUpdates(_ updates: [Odds]) -> UpdateResult {
        guard !updates.isEmpty else { return (cachedList, [:]) }

        let updatesMap = Dictionary(
            updates.map { ($0.matchID, $0) },
            uniquingKeysWith: { _, last in last }
        )

        var list = cachedList
        var changes: [Int: OddsHighlightSide] = [:]

        for (idx, existing) in list.enumerated() {
            guard let update = updatesMap[existing.matchID] else { continue }

            let aChanged = existing.teamAOdds != update.teamAOdds
            let bChanged = existing.teamBOdds != update.teamBOdds

            if aChanged && bChanged {
                changes[existing.matchID] = .both
            } else if aChanged {
                changes[existing.matchID] = .teamA
            } else if bChanged {
                changes[existing.matchID] = .teamB
            }

            list[idx] = MatchCellModel(
                matchID: existing.matchID,
                teamA: existing.teamA,
                teamB: existing.teamB,
                startTime: existing.startTime,
                teamAOdds: update.teamAOdds,
                teamBOdds: update.teamBOdds
            )
        }

        cachedList = list
        return (list, changes)
    }

    private func merge(matches: [Match], odds: [Odds]) -> [MatchCellModel] {
        let oddsByMatch = Dictionary(uniqueKeysWithValues: odds.map { ($0.matchID, $0) })
        return matches.compactMap { m in
            guard let o = oddsByMatch[m.matchID] else { return nil }
            return MatchCellModel(
                matchID: m.matchID,
                teamA: m.teamA,
                teamB: m.teamB,
                startTime: Self.isoFormatter.date(from: m.startTime) ?? .distantPast,
                teamAOdds: o.teamAOdds,
                teamBOdds: o.teamBOdds
            )
        }
    }

    private func sort(_ cells: [MatchCellModel]) -> [MatchCellModel] {
        cells.sorted { $0.startTime < $1.startTime }
    }
}
