//
//  OddsStreamService.swift
//  OpenNet
//
//  Created by Pat Chang on 2026/3/10.
//

import Foundation

/// Service / Actor 層統一回傳 AsyncStream。
///
/// `updates` 與 `disconnected` 以 `nonisolated let` 宣告：
/// - `AsyncStream` 是 Sendable value type，可跨 actor boundary 直接傳遞，
///   不需 `async get`，消除透過 existential 存取時的 isolation 問題。
/// - Continuation 保持 actor-isolated，只從 actor 方法呼叫 `yield()`，
///   由 serial executor 序列化，不存在 data race。
/// `async get`：AsyncStream 在 iOS 17+ SDK 帶有 @MainActor 推斷，
/// 透過 `any OddsStreamProtocol` existential 存取時，
/// `async get` 讓呼叫端可以用 `await` 跨 isolation boundary 取值，
/// 而不需要知道底層實作的 executor。
/// （同步 `let` 實作可直接滿足 `async get` 需求，StubStreamService 不需改）
protocol OddsStreamProtocol: Sendable {
    var updates: AsyncStream<[Odds]> { get async }
    var disconnected: AsyncStream<Void> { get async }
    func start() async
    func stop() async
    func pause() async
    func reconnect() async
}

// 使用 AsyncStream 模擬 WebSocket 賠率推播。
//
// - 每秒觸發一次（Task.sleep loop），每次隨機產生 0~10 筆賠率更新
// - 模擬斷線：15 秒後透過 `disconnectedContinuation.yield(())` 通知上層
// - actor 保護所有可變狀態（lastKnownOdds、重連計數、Task handles）
//
// ## 為何用 AsyncStream 而非 PassthroughSubject
// PassthroughSubject.init() 在 iOS 17+ SDK 標注 @MainActor，
// 與 actor-isolated stored property 的 executor 衝突，需要 nonisolated(unsafe) 或 async init 繞行。
// AsyncStream.init 無 actor 依賴，Continuation 可直接存為 actor-isolated let，
// init 保持同步且零 isolation 衝突。
actor OddsStreamService: OddsStreamProtocol {

    private let matchIDs: [Int]

    // Task handles — 全部在 actor executor 上存取，不需額外加鎖。
    private var timerTask: Task<Void, Never>?
    private var disconnectTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    // Actor-isolated Continuation：只從 actor 方法呼叫 yield()，
    // serial executor 已保證序列化。
    private let updatesContinuation: AsyncStream<[Odds]>.Continuation
    private let disconnectedContinuation: AsyncStream<Void>.Continuation

    // nonisolated let：AsyncStream 是 Sendable，可不經 await 直接跨 boundary 取得。
    nonisolated let updates: AsyncStream<[Odds]>
    nonisolated let disconnected: AsyncStream<Void>

    private let maxUpdatesPerTick = 10
    private let disconnectAfterSeconds: TimeInterval = 15

    // 重連延遲秒數，每次斷線後加倍（1, 2, 4 … maxDelay）
    private var reconnectDelay: TimeInterval = 1.0
    private let maxReconnectDelay: TimeInterval = 30.0
    private let initialReconnectDelay: TimeInterval = 1.0
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 10

    // 記錄每個 matchID 上一次的賠率，讓 randomOdds() 能選擇只改單側。
    private var lastKnownOdds: [Int: (a: Double, b: Double)] = [:]

    // AsyncStream.init 同步呼叫 closure，Continuation 立即可用，
    // 無需 @MainActor 或 async init。
    init(matchIDs: [Int]) {
        self.matchIDs = matchIDs

        var updatesCont: AsyncStream<[Odds]>.Continuation!
        var disconnectedCont: AsyncStream<Void>.Continuation!
        self.updates = AsyncStream { updatesCont = $0 }
        self.disconnected = AsyncStream { disconnectedCont = $0 }

        self.updatesContinuation = updatesCont
        self.disconnectedContinuation = disconnectedCont
    }

    // MARK: - OddsStreamProtocol

    func start() {
        guard !matchIDs.isEmpty else { return }
        guard timerTask == nil else { return }

        reconnectDelay = initialReconnectDelay
        reconnectAttempts = 0
        print("[OddsStream] 連線 start (matchIDs: \(matchIDs.count))")

        // 每秒 tick 一次：Task 在 actor executor 上執行，
        // tick() 直接呼叫（同 actor，無需 await）。
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                tick()
            }
        }

        // 15 秒後模擬斷線
        disconnectTask = Task {
            try? await Task.sleep(for: .seconds(disconnectAfterSeconds))
            guard !Task.isCancelled else { return }
            print("[OddsStream] 模擬斷線，發出 disconnected 事件")
            stop()
            disconnectedContinuation.yield(())
        }
    }

    func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        disconnectTask?.cancel()
        disconnectTask = nil
        timerTask?.cancel()
        timerTask = nil
        print("[OddsStream] 已停止")
    }

    func pause() {
        stop()
        print("[OddsStream] 暫停（進入背景）")
    }

    func reconnect() {
        guard reconnectAttempts < maxReconnectAttempts else {
            print("[OddsStream] 已達最大重連次數 (\(maxReconnectAttempts))，停止重連")
            return
        }

        reconnectAttempts += 1
        let delay = reconnectDelay
        print("[OddsStream] 第 \(reconnectAttempts) 次重連，延遲 \(delay)s")
        reconnectDelay = min(reconnectDelay * 2, maxReconnectDelay)

        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            start()
        }
    }

    // MARK: - Private

    private func tick() {
        let count = Int.random(in: 0...min(maxUpdatesPerTick, matchIDs.count))
        let selectedIDs = matchIDs.shuffled().prefix(count)
        let updates = selectedIDs.map { randomOdds(for: $0) }
        guard !updates.isEmpty else { return }
        print("[OddsStream] 推播 \(updates.count) 筆 \(updates.map(\.matchID))")
        updatesContinuation.yield(updates)
    }

    private func randomOdds(for matchID: Int) -> Odds {
        guard let current = lastKnownOdds[matchID] else {
            let a = Double.random(in: 1.05...10.2)
            let b = Double.random(in: 1.05...20.2)
            lastKnownOdds[matchID] = (a: a, b: b)
            return Odds(matchID: matchID, teamAOdds: a, teamBOdds: b)
        }

        let changeA = Bool.random()
        let changeB = !changeA || Bool.random()

        let newA = changeA ? Double.random(in: 1.05...10.2) : current.a
        let newB = changeB ? Double.random(in: 1.05...20.2) : current.b

        lastKnownOdds[matchID] = (a: newA, b: newB)
        return Odds(matchID: matchID, teamAOdds: newA, teamBOdds: newB)
    }
}
