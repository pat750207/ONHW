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
        let pipelineRebuilt = await repository.reconnectStream()
        if pipelineRebuilt {
            // Repository 重建了整條 pipeline（背景回前景）
            // 舊的 oddsTask / disconnectTask 的 for await 已自然退出，需重新訂閱新 streams
            print("[VM] pipeline 已重建，重新訂閱 streams")
            await resubscribeStreams()
        }
        // else：streams 仍然存活（WebSocket 自動斷線），既有 Task 繼續接收，不需重訂閱
    }

    private func resubscribeStreams() async {
        guard let updatesStream = await repository.getUpdatesStream(),
              let disconnectedStream = await repository.getDisconnectedStream() else { return }

        oddsTask?.cancel()
        oddsTask = Task { [weak self] in
            guard let self else { return }
            for await (list, changes) in updatesStream {
                guard !Task.isCancelled else { break }
                if !changes.isEmpty { self.changesSubject.send(changes) }
                self.listSubject.send(list)
            }
        }

        disconnectTask?.cancel()
        disconnectTask = Task { [weak self] in
            guard let self else { return }
            for await _ in disconnectedStream {
                guard !Task.isCancelled else { break }
                print("[VM] 收到斷線事件，觸發重連")
                await self.reconnectStream()
            }
        }
    }

    private func startOddsStream(for matchIDs: [Int]) async {
        await repository.startStream(for: matchIDs)

        guard let updatesStream = await repository.getUpdatesStream(),
              let disconnectedStream = await repository.getDisconnectedStream() else { return }

        oddsTask?.cancel()
        oddsTask = Task { [weak self] in
            guard let self else { return }
            for await (list, changes) in updatesStream {
                guard !Task.isCancelled else { break }
                if !changes.isEmpty { self.changesSubject.send(changes) }
                self.listSubject.send(list)
            }
        }

        disconnectTask?.cancel()
        disconnectTask = Task { [weak self] in
            guard let self else { return }
            for await _ in disconnectedStream {
                guard !Task.isCancelled else { break }
                print("[VM] 收到斷線事件，觸發重連")
                await self.reconnectStream()
            }
        }
    }
}
