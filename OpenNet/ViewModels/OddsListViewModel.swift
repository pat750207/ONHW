//
//  OddsListViewModel.swift
//  OpenNet
//
//  Created by Pat Chang on 2026/3/11.
//

import Combine
import Foundation

/// 比賽列表的 ViewModel —— 整個畫面的「單一資料源」。
///
/// **分層架構**：
/// - Service 層：AsyncStream（thread-safe，無 actor isolation 問題）
/// - Repository 層：暴露 AsyncStream 給 ViewModel
/// - ViewModel 層（此層）：將 AsyncStream 以 `Task + for await` 轉為
///   `CurrentValueSubject` / `PassthroughSubject`，驅動 Combine Publisher
/// - View 層：訂閱 Publisher 更新 UI
///
/// **Thread-Safety**：
/// `@MainActor` 宣告，所有屬性與方法均在主線程執行，
/// `for await` loop 跑在 `@MainActor` Task 中，await 後自動回到主線程，
/// 無需手動 `await MainActor.run { }`。

// 1. 呼叫 OddsRepository 取得初始快照，推送至 listPublisher
// 2. 以 Task + for-await 消費 Repository 暴露的 AsyncStream
// 3. 透過 Repository 管理 stream 生命週期（pause / reconnect）
@MainActor
final class OddsListViewModel {

    private let repository: OddsRepository

    private var loadTask: Task<Void, Never>?
    private var oddsTask: Task<Void, Never>?
    private var disconnectTask: Task<Void, Never>?

    // 單一資料源：所有 UI 資料從這裡流出，不對外暴露可變狀態。
    private let listSubject = CurrentValueSubject<[MatchCellModel], Never>([])
    private let changesSubject = PassthroughSubject<[Int: OddsHighlightSide], Never>()
    private let errorSubject = PassthroughSubject<APIError, Never>()

    // @MainActor 保證 send 在主線程，.receive(on: DispatchQueue.main) 無必要。
    var listPublisher: AnyPublisher<[MatchCellModel], Never> {
        listSubject.eraseToAnyPublisher()
    }

    var errorPublisher: AnyPublisher<APIError, Never> {
        errorSubject.eraseToAnyPublisher()
    }

    var changesPublisher: AnyPublisher<[Int: OddsHighlightSide], Never> {
        changesSubject.eraseToAnyPublisher()
    }

    init(repository: OddsRepository) {
        self.repository = repository
    }

    // load cache first，REST 回傳後覆蓋
    func load() {
        loadTask?.cancel()
        // Task 在 @MainActor 上建立，await 後自動回到 MainActor。
        loadTask = Task { [weak self] in
            guard let self else { return }

            let cached = await self.repository.cachedList
            if !cached.isEmpty {
                self.listSubject.send(cached)
            }

            guard !Task.isCancelled else { return }

            do {
                let cells = try await self.repository.fetchSnapshot()
                guard !Task.isCancelled else { return }
                await self.startOddsStream(for: cells.map(\.matchID))
                self.listSubject.send(cells)
            } catch {
                self.errorSubject.send(error as? APIError ?? .networkFailed)
            }
        }
    }

    func pauseStream() async {
        print("[VM] 暫停串流")
        await repository.pauseStream()
    }

    func reconnectStream() async {
        print("[VM] 觸發重連")
        await repository.reconnectStream()
    }

    private func startOddsStream(for matchIDs: [Int]) async {
        await repository.startStream(for: matchIDs)

        // 在 @MainActor context 取得 stream service，
        // 再 await stream.updates / stream.disconnected：
        // AsyncStream 帶有 @MainActor 推斷，從 @MainActor context 存取合法，
        // 無需 nonisolated(unsafe) 或額外繞行。
        guard let stream = await repository.activeStream else { return }
        let oddsStream = await stream.updates
        let disconnectedStream = await stream.disconnected

        // AsyncStream → CurrentValueSubject / PassthroughSubject
        // Task 繼承 @MainActor context，await repository 後自動回到主線程，
        // send() 在主線程執行，無需額外 receive(on:) 或 MainActor.run。
        oddsTask?.cancel()
        oddsTask = Task { [weak self] in
            guard let self else { return }
            for await odds in oddsStream {
                guard !Task.isCancelled else { break }
                print("[VM] 收到 \(odds.count) 筆賠率更新 \(odds.map(\.matchID))")
                let (list, changes) = await self.repository.applyUpdates(odds)
                if !changes.isEmpty { self.changesSubject.send(changes) }
                self.listSubject.send(list)
            }
        }

        disconnectTask?.cancel()
        disconnectTask = Task { [weak self] in
            guard let self else { return }
            for await _ in disconnectedStream {
                guard !Task.isCancelled else { break }
                print("[VM] 收到斷線事件，觸發 exponential backoff 重連")
                await self.repository.reconnectStream()
            }
        }
    }
}
