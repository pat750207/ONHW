//
//  OddsRepository.swift
//  OpenNet
//
//  Created by Pat Chang on 2026/3/12.
//

import Combine
import Foundation

// Repository Pattern
// 所有資料的唯一窗口：REST、WebSocket、cache、applyUpdates
// Repository 持有 WebSocket 但「不訂閱」只給 Publisher，由 ViewModel 決定何時 subscribe / batch
final class OddsRepository {

    private let apiService: MatchAPIServiceProtocol
    private let oddsStreamFactory: ([Int]) -> OddsStreamProtocol

    private var oddsStream: OddsStreamProtocol?

    private(set) var cachedList: [MatchCellModel] = []

    // ViewModel 訂閱此 Publisher 取得原始 [Odds] 推播
    // Repository 只是轉接，不執行 .sink
    var oddsPublisher: AnyPublisher<[Odds], Never> {
        oddsStream?.updates ?? Empty().eraseToAnyPublisher()
    }

    // 斷線事件 Publisher，ViewModel 收到後決定是否呼叫 reconnectStream()
    var disconnectedPublisher: AnyPublisher<Void, Never> {
        oddsStream?.disconnected ?? Empty().eraseToAnyPublisher()
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init(
        apiService: MatchAPIServiceProtocol,
        oddsStreamFactory: @escaping ([Int]) -> OddsStreamProtocol = { OddsStreamService(matchIDs: $0) }
    ) {
        self.apiService = apiService
        self.oddsStreamFactory = oddsStreamFactory
    }

    // 建立並啟動串流。
    func startStream(for matchIDs: [Int]) {
        let stream = oddsStreamFactory(matchIDs)
        self.oddsStream = stream
        stream.start()
    }

    func pauseStream() {
        print("[Repository] 暫停串流")
        oddsStream?.pause()
    }

    func reconnectStream() {
        print("[Repository] 觸發重連")
        oddsStream?.reconnect()
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
