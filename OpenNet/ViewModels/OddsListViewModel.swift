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
/// **Thread-Safety **：
/// - 所有對 `listSubject` 的寫入都保證在 MainActor 上執行
/// - REST 回傳後以 `MainActor.run` 切回主線程
/// - WebSocket 更新經 Combine `collect` + `receive(on: .main)` 批次處理
///
/// **效能**：
/// - 高頻推送使用 `collect(.byTime(..., 100ms))` 批次合併，
///   每 100ms 最多觸發一次 UI 更新，維持 60fps 流暢度


// 1. 呼叫 OddsRepository 取得初始快照，推送至 listPublisher
// 2. 訂閱 Repository 暴露的 oddsPublisher，批次委派 Repository 套用更新，再推送結果
// 3. 透過 Repository 管理 stream 生命週期（pause / reconnect）
final class OddsListViewModel {

    private let repository: OddsRepository

    private var cancellables = Set<AnyCancellable>()

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

    //load cache first
    func load() {
        if !repository.cachedList.isEmpty {
            listSubject.send(repository.cachedList)
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                // Repository 負責 fetch + merge + sort + 寫 cache
                let cells = try await repository.fetchSnapshot()
                await MainActor.run {
                    self.listSubject.send(cells)
                    self.startOddsStream(for: cells.map(\.matchID))
                }
            } catch {
                await MainActor.run {
                    self.errorSubject.send(error as? APIError ?? .networkFailed)
                }
            }
        }
    }

    func pauseStream() {
        print("[VM] 暫停串流")
        repository.pauseStream()
    }

    func reconnectStream() {
        print("[VM] 觸發重連")
        repository.reconnectStream()
    }

    private func startOddsStream(for matchIDs: [Int]) {
        // 請 Repository 建立並啟動串流
        repository.startStream(for: matchIDs)

        // 訂閱 Repository 暴露的 oddsPublisher（Repository 不 sink，只轉接）
        // ViewModel 負責 100ms 批次合併（UI 優化）每秒最最多10筆
        repository.oddsPublisher
            .collect(.byTime(DispatchQueue.main, .milliseconds(100)))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] batchedArrays in
                let allUpdates = batchedArrays.flatMap { $0 }
                self?.applyOddsUpdates(allUpdates)
            }
            .store(in: &cancellables)

        repository.disconnectedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                print("[VM] 收到斷線事件，觸發 exponential backoff 重連")
                self?.repository.reconnectStream()
            }
            .store(in: &cancellables)
    }

    private func applyOddsUpdates(_ updates: [Odds]) {
        guard !updates.isEmpty else { return }
        print("[VM] 收到 \(updates.count) 筆賠率更新 \(updates.map(\.matchID))")
        // 送回 repository 做資料處理
        let (list, changes) = repository.applyUpdates(updates)
        listSubject.send(list)
        if !changes.isEmpty {
            changesSubject.send(changes)
        }
    }
}
