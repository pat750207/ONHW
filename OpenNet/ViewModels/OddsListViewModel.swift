//
//  OddsListViewModel.swift
//  OpenNet
//
//  Created by Pat Chang on 2026/3/11.
//

@preconcurrency import Combine
import Foundation

/// 比賽列表的 ViewModel —— 整個畫面的「單一資料源」。
///
/// **Thread-Safety**：
/// - UI 更新（Subject.send）一律透過 `MainActor.run` 切回主線程
/// - 資料層由 actor queue 化，UI 層由 MainActor queue化
/// **效能**：
/// - 高頻推送使用 `collect(.byTime(..., 100ms))` 批次合併，
///   每 100ms 最多觸發一次 UI 更新，維持 60fps 流暢度

// 1. 呼叫 OddsRepository 取得初始快照，推送至 listPublisher
// 2. 訂閱 Repository 暴露的 oddsPublisher，在 actor 背景執行
// 3. 透過 Repository 管理 stream 生命週期（pause / reconnect）
final class OddsListViewModel {

    private let repository: OddsRepository

    private var cancellables = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?

    // 單一資料源：所有 UI 資料從這裡流出，不對外暴露可變狀態。
    private let listSubject = CurrentValueSubject<[MatchCellModel], Never>([])

    private let changesSubject = PassthroughSubject<[Int: OddsHighlightSide], Never>()

    private let errorSubject = PassthroughSubject<APIError, Never>()

    var listPublisher: AnyPublisher<[MatchCellModel], Never> {
        listSubject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    var errorPublisher: AnyPublisher<APIError, Never> {
        errorSubject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    var changesPublisher: AnyPublisher<[Int: OddsHighlightSide], Never> {
        changesSubject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    init(repository: OddsRepository) {
        self.repository = repository
    }

    // load cache first，REST 回傳後覆蓋
    func load() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }

            // load actor cache
            let cached = await self.repository.cachedList
            if !cached.isEmpty {
                await MainActor.run { self.listSubject.send(cached) }
            }

            guard !Task.isCancelled else { return }

            do {
                // fetchSnapshot 在 actor 背景 do fetch + merge + sort + 寫 cache
                let cells = try await self.repository.fetchSnapshot()
                guard !Task.isCancelled else { return }
                // 先啟動websocket，訂閱就緒後 UI 才顯示資料
                await self.startOddsStream(for: cells.map(\.matchID))
                await MainActor.run { self.listSubject.send(cells) }
            } catch {
                await MainActor.run {
                    self.errorSubject.send(error as? APIError ?? .networkFailed)
                }
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
        //  repository actor
        await repository.startStream(for: matchIDs)
        let oddsPublisher = await repository.oddsPublisher
        let disconnectedPublisher = await repository.disconnectedPublisher

        // 切回 MainActor , cancellables 的讀寫在主線程
        await MainActor.run { [weak self] in
            guard let self else { return }

            oddsPublisher
                .collect(.byTime(DispatchQueue.main, .milliseconds(100)))
                .receive(on: DispatchQueue.main)
                .sink { [weak self] batchedArrays in
                    let allUpdates = batchedArrays.flatMap { $0 }
                    guard let self, !allUpdates.isEmpty else { return }
                    print("[VM] 收到 \(allUpdates.count) 筆賠率更新 \(allUpdates.map(\.matchID))")
                    // applyUpdates 資料處理 在 actor background executor ）
                    Task { [weak self] in
                        guard let self else { return }
                        let (list, changes) = await self.repository.applyUpdates(allUpdates)
                        await MainActor.run {
                            if !changes.isEmpty { self.changesSubject.send(changes) }
                            self.listSubject.send(list)
                        }
                    }
                }
                .store(in: &self.cancellables)

            disconnectedPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    print("[VM] 收到斷線事件，觸發 exponential backoff 重連")
                    Task { [weak self] in await self?.repository.reconnectStream() }
                }
                .store(in: &self.cancellables)
        }
    }
}
