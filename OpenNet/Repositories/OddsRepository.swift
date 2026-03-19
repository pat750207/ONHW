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
// - Service 層（OddsStreamService）只負責產出 [Odds] 與斷線事件
// - Repository 建立並持有 stream、在內部消費 updates/disconnected，
//   轉成「已合併的 (list, changes)」與斷線事件，對外只暴露這兩條 AsyncStream
// - ViewModel 只訂閱 Repository 的 updatesStream / disconnectedStream，不認識 OddsStreamProtocol
actor OddsRepository {

    private let apiService: any MatchAPIServiceProtocol
    private let oddsStreamFactory: ([Int]) async -> any OddsStreamProtocol

    private var oddsStream: (any OddsStreamProtocol)?

    // 記錄最後一次啟動用的 matchIDs，reconnect 時需要重新 startStream
    private var lastMatchIDs: [Int] = []

    /// 對外暴露：已合併的 (list, changes)，由 Repository 內部消費 OddsStreamService 後 yield
    private var _updatesStream: AsyncStream<UpdateResult>?
    private var _updatesContinuation: AsyncStream<UpdateResult>.Continuation?
    /// 對外暴露：斷線事件，由 Repository 內部轉發
    private var _disconnectedStream: AsyncStream<Void>?
    private var _disconnectedContinuation: AsyncStream<Void>.Continuation?

    // 消費 OddsStreamService 的 Task handles，需要在 finishStreams 時取消
    private var updatesConsumerTask: Task<Void, Never>?
    private var disconnectedConsumerTask: Task<Void, Never>?

    private(set) var cachedList: [MatchSummary] = []

    // for highlight，對外 stream 與 applyUpdates 共用
    typealias UpdateResult = (list: [MatchSummary], changes: [Int: OddsHighlightSide])

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

    /// ViewModel 取得「已合併更新」流，不需認識 OddsStreamProtocol
    func getUpdatesStream() -> AsyncStream<UpdateResult>? { _updatesStream }

    /// ViewModel 取得斷線事件流
    func getDisconnectedStream() -> AsyncStream<Void>? { _disconnectedStream }

    func startStream(for matchIDs: [Int]) async {
        finishStreams()

        lastMatchIDs = matchIDs

        let stream = await oddsStreamFactory(matchIDs)
        self.oddsStream = stream
        await stream.start()

        var updatesCont: AsyncStream<UpdateResult>.Continuation!
        var disconnectedCont: AsyncStream<Void>.Continuation!
        _updatesStream = AsyncStream<UpdateResult> { updatesCont = $0 }
        _disconnectedStream = AsyncStream<Void> { disconnectedCont = $0 }
        _updatesContinuation = updatesCont
        _disconnectedContinuation = disconnectedCont

        let updates = await stream.updates
        let disconnected = await stream.disconnected

        // Task handle 存起來，finishStreams 時取消，避免 zombie Task
        updatesConsumerTask = Task {
            for await odds in updates {
                let result = await self.applyUpdates(odds)
                await self.yieldUpdate(result)
            }
        }
        disconnectedConsumerTask = Task {
            for await _ in disconnected {
                await self.yieldDisconnected()
            }
        }
    }

    private func yieldUpdate(_ result: UpdateResult) {
        _updatesContinuation?.yield(result)
    }

    private func yieldDisconnected() {
        _disconnectedContinuation?.yield(())
    }

    private func finishStreams() {
        // consumer Tasks 先取消，避免殘留 Task 繼續處理資料
        updatesConsumerTask?.cancel()
        updatesConsumerTask = nil
        disconnectedConsumerTask?.cancel()
        disconnectedConsumerTask = nil
        _updatesContinuation?.finish()
        _updatesContinuation = nil
        _updatesStream = nil
        _disconnectedContinuation?.finish()
        _disconnectedContinuation = nil
        _disconnectedStream = nil
    }

    func pauseStream() async {
        print("[Repository] 暫停串流")
        await oddsStream?.pause()
        finishStreams()
    }

    /// 回傳 true 代表 pipeline 已重建（新的 streams），ViewModel 需要重新訂閱
    /// 回傳 false 代表既有 streams 仍然存活，ViewModel 的 Task 繼續接收即可
    @discardableResult
    func reconnectStream() async -> Bool {
        print("[Repository] 觸發重連")
        if _updatesContinuation == nil, !lastMatchIDs.isEmpty {
            // streams 已被 pause/finish（例如 App 進入背景後回前景）
            // → 重建整條 pipeline，立即恢復資料流
            print("[Repository] streams 已結束，重建 pipeline（matchIDs: \(lastMatchIDs.count)）")
            await startStream(for: lastMatchIDs)
            return true
        } else {
            // streams 仍然存活（例如 WebSocket 自動斷線）
            // → 保留既有 pipeline，只重啟底層 service（含 exponential backoff）
            await oddsStream?.reconnect()
            return false
        }
    }

    // get matches + odds，合併、排序，更新快取後回傳結果。
    func fetchSnapshot() async throws -> [MatchSummary] {
        async let matches = apiService.fetchMatches()
        async let odds = apiService.fetchOdds()
        let (m, o) = try await (matches, odds)
        let cells = sort(merge(matches: m, odds: o))
        cachedList = cells
        return cells
    }

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

            list[idx] = MatchSummary(
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

    private func merge(matches: [Match], odds: [Odds]) -> [MatchSummary] {
        let oddsByMatch = Dictionary(uniqueKeysWithValues: odds.map { ($0.matchID, $0) })
        return matches.compactMap { m in
            guard let o = oddsByMatch[m.matchID] else { return nil }
            return MatchSummary(
                matchID: m.matchID,
                teamA: m.teamA,
                teamB: m.teamB,
                startTime: Self.isoFormatter.date(from: m.startTime) ?? .distantPast,
                teamAOdds: o.teamAOdds,
                teamBOdds: o.teamBOdds
            )
        }
    }

    private func sort(_ cells: [MatchSummary]) -> [MatchSummary] {
        cells.sorted { $0.startTime < $1.startTime }
    }
}
