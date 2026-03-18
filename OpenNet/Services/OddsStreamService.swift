//
//  OddsStreamService.swift
//  OpenNet
//
//  Created by Pat Chang on 2026/3/10.
//

@preconcurrency import Combine
import Foundation

/// for test and inject
protocol OddsStreamProtocol: AnyObject {
    var updates: AnyPublisher<[Odds], Never> { get }
    var disconnected: AnyPublisher<Void, Never> { get }
    func start()
    func stop()
    func pause()
    func reconnect()
}

// 使用 Combine Timer 模擬 WebSocket 賠率推播。
//
// - 每秒觸發一次 Timer，每次隨機產生 0~10 筆賠率更新
// - 模擬斷線：15 秒後自動觸發 `disconnected` 事件，ViewModel 收到後以啟動重連機制。
final class OddsStreamService: OddsStreamProtocol {

    private let matchIDs: [Int]
    private var timerCancellable: AnyCancellable?
    private let subject = PassthroughSubject<[Odds], Never>()
    private let disconnectedSubject = PassthroughSubject<Void, Never>()

    private var disconnectWorkItem: DispatchWorkItem?

    private(set) var isPaused = false
    private let maxUpdatesPerTick = 10
    private let disconnectAfterSeconds: TimeInterval = 15


    // 重連延遲秒數，每次斷線後加倍（1,2,4...,maxDelay），
    private var reconnectDelay: TimeInterval = 1.0
    private let maxReconnectDelay: TimeInterval = 30.0
    private let initialReconnectDelay: TimeInterval = 1.0
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 10
    private var reconnectTask: Task<Void, Never>?

    // 記錄每個 matchID 上一次的賠率，讓 randomOdds() 能選擇只改單側。
    private var lastKnownOdds: [Int: (a: Double, b: Double)] = [:]

    init(matchIDs: [Int]) {
        self.matchIDs = matchIDs
    }

    func start() {
        guard !matchIDs.isEmpty else { return }
        guard timerCancellable == nil else { return }

        isPaused = false
        /// 連線後reset backoff
        reconnectDelay = initialReconnectDelay
        reconnectAttempts = 0
        print("[OddsStream] 連線 start (matchIDs: \(matchIDs.count))")

        timerCancellable = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .map { [weak self] _ -> [Odds] in
                guard let self else { return [] }
                let count = Int.random(in: 0...min(self.maxUpdatesPerTick, self.matchIDs.count))
                let selectedIDs = self.matchIDs.shuffled().prefix(count)
                return selectedIDs.map { self.randomOdds(for: $0) }
            }
            .filter { !$0.isEmpty }
            .handleEvents(receiveOutput: { updates in
                let ids = updates.map(\.matchID)
                print("[OddsStream] 推播 \(updates.count) 筆 \(ids)")
            })
            .subscribe(subject)

        scheduleDisconnectSimulation()
    }

    func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        disconnectWorkItem?.cancel()
        disconnectWorkItem = nil
        timerCancellable?.cancel()
        timerCancellable = nil
        print("[OddsStream] 已停止")
    }

    func pause() {
        isPaused = true
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
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    var updates: AnyPublisher<[Odds], Never> {
        subject.eraseToAnyPublisher()
    }

    /// 每 15 秒斷一次 ViewModel收到後觸發重連
    var disconnected: AnyPublisher<Void, Never> {
        disconnectedSubject.eraseToAnyPublisher()
    }

    private func scheduleDisconnectSimulation() {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            print("[OddsStream] 模擬斷線，發出 disconnected 事件")
            self.stop()
            self.disconnectedSubject.send()
        }
        disconnectWorkItem = workItem
        // 在 main queue 排程，確保 stop() 與 subject.send 都在 main 執行 for safe。
        DispatchQueue.main.asyncAfter(deadline: .now() + disconnectAfterSeconds, execute: workItem)
    }

    /// 隨機產生一筆賠率更新
    private func randomOdds(for matchID: Int) -> Odds {
        guard let current = lastKnownOdds[matchID] else {
            // 第一次：兩側都初始化
            let a = Double.random(in: 1.05...10.2)
            let b = Double.random(in: 1.05...20.2)
            lastKnownOdds[matchID] = (a: a, b: b)
            return Odds(matchID: matchID, teamAOdds: a, teamBOdds: b)
        }

        // 隨機決定改哪一側（確保至少一側改變）
        let changeA = Bool.random()
        let changeB = !changeA || Bool.random()  // A 不改時 B 改

        let newA = changeA ? Double.random(in: 1.05...10.2) : current.a
        let newB = changeB ? Double.random(in: 1.05...20.2) : current.b

        lastKnownOdds[matchID] = (a: newA, b: newB)
        return Odds(matchID: matchID, teamAOdds: newA, teamBOdds: newB)
    }
}
