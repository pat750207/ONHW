# ONHW — 即時資料展示系統

UIKit 即時資料展示 App。採用 **MVVM** 架構，整合 REST API Mock、WebSocket 串流模擬、thread-safe 資料處理與即時 UI 更新。

---

## PDF 需求


| 需求                             | 實作方式                                                                                                  |
| ------------------------------ | ----------------------------------------------------------------------------------------------------- |
| UIKit 應用程式                     | UIViewController + UITableView + DiffableDataSource                                                   |
| MVVM 架構                        | ViewController（View）/ OddsListViewModel / Repository + Service + Model                                |
| Swift Concurrency 或 Combine    | REST 單發請求用 **async/await**；串流與 UI 綁定用 **Combine**                                                     |
| GET /matches：約 100 筆           | `MockAPIService` 記憶體產生 100 筆 Match（matchID、隊伍名稱、比賽時間）                                                 |
| GET /odds：初始賠率                 | `MockAPIService` 同步產生 100 筆 Odds（teamAOdds、teamBOdds）                                                 |
| WebSocket 模擬：每秒最多 10 筆         | `OddsStreamService` 以 `Timer.publish(every: 1s)` + random 0~10 筆模擬推播                                  |
| 比賽時間升序排列                       | `sortByStartTimeAscending` 在初始合併後排序，推播更新不改變順序                                                         |
| 賠率更新 — 對應 cell 即時更新，不整頁 reload | `DiffableDataSource.reconfigureItems` 原地更新 cell 內容，不呼叫 `reloadData`                                   |
| 畫面流暢（60fps）                    | 批次合併（100ms）+ static DateFormatter 快取 + DiffableDataSource 自動 diff + **FPSMonitor（CADisplayLink）即時監測** |
| Thread-safe 資料存取               | 所有寫入限定 MainActor，單一 `CurrentValueSubject` 為資料源，無共享可變狀態                                                |
| Mock 資料用記憶體或 JSON              | `MockAPIService` 以記憶體直接產生結構化資料                                                                        |
| **加分：斷線自動重連**                  | Exponential backoff（1s → 2s → 4s → … → 最大 30s，最多 10 次）                                                |
| **加分：快取機制**                    | `OddsRepository` 由 SceneDelegate 持有，跨 ViewModel 生命週期；`load()` 時先顯示快取再背景拉取最新資料                         |


---

## 架構說明

### 1. Swift Concurrency 與 Combine 的使用場景

**Swift Concurrency（async/await）— 單發 REST 請求**

`MatchAPIServiceProtocol` 定義 `fetchMatches() async throws` 與 `fetchOdds() async throws`。ViewModel 在 `load()` 以 `async let` 並行發送兩個請求，取得後透過 `MainActor.run` 切回主線程合併。

選擇 async/await 的理由：REST 是「一次請求，`try await` 的線性寫法比 Publisher chain 直觀，並行只需 `async let`，不必組合 `CombineLatest` 或 `Zip`。

**Combine — WebSocket 串流與 UI 綁定**

`OddsStreamService` 以 `Timer.publish` 模擬持續推播。Repository 持有串流實體並暴露 `oddsPublisher`（不 sink），ViewModel 訂閱後以 `collect(.byTime(..., 100ms))` 批次合併高頻事件，再透過 `CurrentValueSubject` 推送給 ViewController。

選擇 Combine 的理由：串流是「持續多筆事件、不知何時結束」的模型，Combine 的 `collect`、`receive(on:)`、`cancellables` 生命週期管理正是為此設計；相較之下 async/await 沒有內建批次，取消也需手動管理。

---

### 2. Thread-safe 資料存取

採用 **MainActor 序列化** ，以 Swift 內建的 Global Actor 自動鎖「主執行緒」這條串行佇列。標記或切入 MainActor 的程式碼只在主線程執行，不用手動加鎖。

**單一資料源（Single Source of Truth）**：比賽列表由 `CurrentValueSubject<[MatchCellModel], Never>` 外部只能訂閱，無法直接修改。

**所有寫入透過 MainActor 序列化**：REST 回傳後以 `await MainActor.run { }` 切回主線程寫入 Subject；WebSocket 更新以 `collect(.byTime)` 批次合併後經 `receive(on: DispatchQueue.main)` 再寫入。讀取端（ViewController 的 `sink`）同樣在主線程，確保同一份資料的讀與寫永遠在同一條線程，無 Race Condition。

---

### 3. UI 與 ViewModel 資料綁定

**綁定流程**：ViewController 在 `bindViewModel()` 訂閱 ViewModel 三條 Publisher，單向資料流（ViewModel → View）：


| Publisher          | 用途                                                                            |
| ------------------ | ----------------------------------------------------------------------------- |
| `listPublisher`    | 收到新列表 → `applySnapshot(with: items)`，更新 DiffableDataSource                    |
| `changesPublisher` | 收到「哪些 matchID 賠率變動、變哪一側」→ 暫存至 `pendingChanges`，供下次 apply 時 reconfigure + 高亮動畫 |
| `errorPublisher`   | 顯示錯誤 Alert                                                                    |


**applySnapshot 流程**：先更新 `itemLookup`（matchID → 顯示用 Model）→ 建立 Snapshot（item = matchID）→ 取出並清空 `pendingChanges` → 對有變動的 ID 呼叫 `reconfigureItems` → `dataSource.apply(snapshot)`；在 apply 的 completion 中對可見且變動的 cell 呼叫 `animateOddsHighlight(side:)`。因此 **先送 changes、再送 list**，VC 才能在同一輪 apply 裡同時更新數字與播放高亮。

**技術選擇**：用 **DiffableDataSource + reconfigureItems** 原地更新 cell 內容、不整頁 reload、不觸發 insert/delete 動畫；item identifier 用 `Int`（matchID）。

**批次更新**：ViewModel 以 `collect(.byTime(DispatchQueue.main, .milliseconds(100)))` 將 100ms 內合為一次更新，再送 list + changes，避免逐筆觸發 layout，維持 60fps。

---

## 加分項目

### WebSocket 斷線自動重連（Exponential Backoff）

`OddsStreamService` 模擬每 15 秒斷線一次，斷線時透過 `disconnectedSubject` 發出事件。Repository 暴露 `disconnectedPublisher`，ViewModel 訂閱後呼叫 `repository.reconnectStream()`，重連延遲從 1 秒開始每次加倍（1s → 2s → 4s → 8s → 16s → 上限 30s），設定最大重連次數（10 次）防止無限重試。連線成功後延遲與次數自動重置。

ViewController 另外監聽 `willResignActive` / `didBecomeActive`，App 進入背景時暫停串流，回前景時自動恢復，節省背景資源。

### 快取

快取由獨立的 `OddsRepository` 持有，`**AppContainer`（Composition Root）** 建立並注入至 ViewModel。生命週期與 `AppContainer`（= Scene）綁定，而非與 ViewModel 綁定。

```
SceneDelegate
  └── AppContainer
        ├── apiService（MockAPIService）
        └── repository（OddsRepository）
              ├── apiService           ← REST 呼叫封裝在此
              ├── oddsStreamFactory    ← WebSocket 串流工廠（持有但不訂閱）
              ├── oddsPublisher        ← 暴露原始 [Odds] Publisher，ViewModel subscribe
              ├── disconnectedPublisher← 暴露斷線事件 Publisher
              ├── startStream / pauseStream / reconnectStream ← 生命週期方法
              └── cachedList           ← in-memory 快取
        makeOddsListViewModel() → OddsListViewModel(repository:)
              → load() 呼叫 repository.fetchSnapshot() 取初始資料
              → 先 send repository.cachedList → 背景 REST 覆蓋 → 寫回 repository
```

ViewModel 只依賴 `OddsRepository`，是所有資料的唯一窗口（REST + WebSocket + cache）。Repository 持有串流但不訂閱（不做 `.sink`），只暴露 `oddsPublisher` 讓 ViewModel 自行 subscribe + 100ms 批次。ViewModel 只管 Combine 狀態（Subject / Publisher）與 UI 驅動。VC 因 push/pop 被 dealloc、ViewModel 隨之釋放，`AppContainer` 持有的 `repository` 仍然存活，重建 ViewModel 時快取依然有效。

---

## 專案結構

```
OpenNet/
├── AppDelegate.swift
├── SceneDelegate.swift              ← Scene 生命週期；持有 AppContainer，組裝視窗
├── AppContainer.swift               ← 建立並持有共享依賴、提供 factory method
├── Models/
│   ├── Match.swift                  ← GET /matches 資料結構（Codable, Sendable）
│   ├── Odds.swift                   ← GET /odds + WebSocket 共用（Codable, Sendable）
│   ├── OddsHighlightSide.swift      ← 賠率變動方向（teamA / teamB / both）
│   └── MatchCellModel.swift         ← 顯示用 Model / DTO（Identifiable, Sendable）
├── ViewModels/
│   └── OddsListViewModel.swift      ← 訂閱 Repository Publisher、collect 100ms 批次、changesPublisher
├── ViewControllers/
│   └── OddsListViewController.swift ← DiffableDataSource、UI 綁定、pendingChanges 動畫、App 生命週期
├── Views/
│   ├── OddsListTableViewCell.swift  ← UI
│   └── FPSMonitor.swift             ← CADisplayLink FPS 即時監測（Debug 用）
├── Repositories/
│   └── OddsRepository.swift          ← Repository Pattern：fetch + merge + sort + cache + applyUpdates + 持有 stream（不訂閱）
└── Services/
    ├── MatchAPIServiceProtocol.swift ← REST 協定 + APIError
    ├── MockAPIService.swift          ← 模擬 REST（100 筆）
    └── OddsStreamService.swift       ← 模擬 WebSocket + Exponential Backoff 重連

OpenNetTests/
├── OddsListViewModelTests.swift     ← 注入 StubAPIService + StubStreamService 測試行為
├── MatchCellModelTests.swift        ← oddsChanged diff helper、Identifiable
└── MockAPIServiceTests.swift        ← Mock 資料格式驗證（100 筆、欄位完整）
```

---

## 測試

單元測試透過注入 stub service 驗證 **ViewModel 實際行為**：

- **OddsListViewModelTests**：透過 Repository 注入 `StubAPIService` + `StubStreamService`，驗證初始載入合併排序正確、推播僅更新對應 matchID 的賠率、API 錯誤正確傳遞至 errorPublisher、pause/reconnect 透過 Repository 轉發至串流
- **MatchCellModelTests**：透過 `OddsRepository.applyUpdates` 驗證各種賠率變動方向（teamA / teamB / both / 無變動）回傳正確的 `OddsHighlightSide`，以及 `Identifiable` identity（matchID）
- **MockAPIServiceTests**：驗證 mock 資料符合 PDF 規格（100 筆、matchID 對齊、欄位完整）

---

