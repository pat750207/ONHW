# ONHW — 即時資料展示系統

UIKit 即時資料展示 App。採用 **MVVM** 架構，整合 REST API Mock、WebSocket 串流模擬、thread-safe 資料處理與即時 UI 更新。

---

## PDF 需求


| 需求                                         | 實作方式                                                                                                                                                                                                 |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| UIKit 應用程式                               | UIViewController + UITableView + DiffableDataSource                                                                                                                                                      |
| MVVM 架構                                    | ViewController（View）/ OddsListViewModel / Repository + Service + Model                                                                                                                                 |
| Swift Concurrency 或 Combine                 | REST 單發請求用 **async/await**；串流與 UI 綁定用 **Combine**                                                                                                                                            |
| GET /matches：約 100 筆                      | `MockAPIService`（struct）記憶體產生 100 筆 Match（matchID、隊伍名稱、比賽時間）                                                                                                                         |
| GET /odds：初始賠率                          | `MockAPIService` 同步產生 100 筆 Odds（teamAOdds、teamBOdds）                                                                                                                                            |
| WebSocket 模擬：每秒最多 10 筆               | `OddsStreamService`（actor）以 `Task.sleep` loop 每秒 tick 一次，每次隨機產生 0~10 筆推播                                                                                                                |
| 比賽時間升序排列                             | `OddsRepository.sort()` 在初始合併後排序，推播更新不改變順序                                                                                                                                            |
| 賠率更新 — 對應 cell 即時更新，不整頁 reload | `DiffableDataSource.reconfigureItems` 原地更新 cell 內容，不呼叫 `reloadData`                                                                                                                            |
| 畫面流暢（60fps）                            | 批次合併（100ms）+ static DateFormatter 快取 + DiffableDataSource 自動 diff + **FPSMonitor（CADisplayLink）即時監測**                                                                                    |
| Thread-safe 資料存取                         | `OddsRepository` 與 `OddsStreamService` 均宣告為 **`actor`**，各自以 serial executor 保護可變狀態；`OddsListViewModel` 標記 **`@MainActor`**，所有 Subject send 在主線程，無需手動 `MainActor.run` |
| Mock 資料用記憶體或 JSON                     | `MockAPIService`（struct）以記憶體直接產生結構化資料                                                                                                                                                     |
| **加分：斷線自動重連**                       | Exponential backoff（1s → 2s → 4s → … → 最大 30s，最多 10 次）                                                                                                                                           |
| **加分：快取機制**                           | `OddsRepository` 由 `AppContainer` 持有（`AppContainer` 由 `SceneDelegate` 持有），跨 ViewModel 生命週期；`load()` 時先顯示快取再背景拉取最新資料                                                        |


---

## 架構說明

### 1. Swift Concurrency 與 Combine 的使用場景

**Swift Concurrency（async/await）— 單發 REST 請求**

`MatchAPIServiceProtocol` 定義 `fetchMatches() async throws` 與 `fetchOdds() async throws`。`OddsRepository.fetchSnapshot()` 以 `async let` 並行發送兩個請求，在 actor background executor 完成 merge + sort 後回傳；ViewModel 取得結果後直接對 Subject 寫入（`@MainActor` 保證在主線程）。

選擇 async/await 的理由：REST 是「一次請求、一次回應」的模型，`try await` 的線性寫法比 Publisher chain 直觀，並行只需 `async let`，不必組合 `CombineLatest` 或 `Zip`。

**分層 Concurrency — WebSocket 串流**

三層各使用最合適的工具，各司其職：

| 層 | 工具 | 理由 |
|----|------|------|
| Service（`OddsStreamService` actor） | `AsyncStream` + actor-isolated `Continuation` | thread-safe value type；actor serial executor 序列化 `yield()`，無需手動加鎖 |
| ViewModel（`@MainActor`） | `Task + for await` | 在 MainActor context 消費串流，await 後自動回到主線程，直接 `send()` 給 Subject，無需 `receive(on:)` 或 `Task { @MainActor in }` |
| View（UIKit） | Combine `AnyPublisher` | `DiffableDataSource` 訂閱 `listPublisher` / `changesPublisher`，單向資料流，`cancellables` 自動管理生命週期 |

`OddsStreamService` 以 `Task.sleep` loop 模擬持續推播，透過 `nonisolated let updates: AsyncStream<[Odds]>` 對外暴露串流。ViewModel 取得 `AsyncStream` 後以 `Task { for await odds in stream { ... } }` 消費，再寫入 `CurrentValueSubject` 驅動 UI。

---

### 2. Thread-safe 資料存取

採用 **Actor 隔離** 分離「串流層」、「資料層」與「UI 層」三條串行佇列，各司其職。

**串流層 — `OddsStreamService` actor**：所有可變狀態（`lastKnownOdds`、`reconnectDelay`、`reconnectAttempts`、Task handles）均受 actor serial executor 保護。計時循環與斷線模擬統一使用 `Task` + `Task.sleep`，消除原先的 `DispatchWorkItem` / `DispatchQueue.main.asyncAfter` 混用。`nonisolated let updates: AsyncStream<[Odds]>` 讓外部無需 actor hop 即可取得串流；actor-isolated `Continuation` 的 `yield()` 只從 actor 方法呼叫，序列化由 actor 隱式保證，無需 `PassthroughSubject` 及其 `@MainActor` 依賴。

**資料層 — `OddsRepository` actor**：`OddsRepository` 宣告為 `actor`，擁有自己的 background serial executor。所有資料處理（merge、sort、applyUpdates、cachedList 讀寫）都在此 executor 序列執行，透過 actor isolation 靜態保證不會有兩段程式碼同時讀寫同一份資料——無需手動加鎖，無 Race Condition。對外暴露 `activeStream: (any OddsStreamProtocol)?`，由 `@MainActor` ViewModel 自行 `await stream.updates` 取得 `AsyncStream`（在 MainActor context 存取，符合 SDK 的 `@MainActor` 推斷）。

**UI 層 — `@MainActor OddsListViewModel`**：ViewModel 宣告 `@MainActor`，所有屬性（Subjects）與方法均保證在主線程執行。以 `Task { for await odds in oddsStream { ... } }` 消費 `AsyncStream`，Task 繼承 `@MainActor` context，`await repository.applyUpdates()` 後自動回到 MainActor，直接 `send()` 給 Subject——無需 `receive(on:)`、`Task { @MainActor in }`，或 `cancellables`。

**單一資料源**：比賽列表由 `CurrentValueSubject<[MatchCellModel], Never>` 持有，外部只能訂閱，無法直接修改。

**資料流**：`OddsStreamService.tick()` → `updatesContinuation.yield()`（actor）→ `for await odds in oddsStream`（@MainActor Task）→ `repository.applyUpdates()`（actor）→ Subject `send()`（MainActor）

---

### 3. UI 與 ViewModel 資料綁定

**綁定流程**：ViewController 在 `bindViewModel()` 訂閱 ViewModel 三條 Publisher，單向資料流（ViewModel → View）：


| Publisher          | 用途                                                                                                     |
| ------------------ | -------------------------------------------------------------------------------------------------------- |
| `listPublisher`    | 收到新列表 → `applySnapshot(with: items)`，更新 DiffableDataSource                                       |
| `changesPublisher` | 收到「哪些 matchID 賠率變動、變哪一側」→ 暫存至 `pendingChanges`，供下次 apply 時 reconfigure + 高亮動畫 |
| `errorPublisher`   | 顯示錯誤 Alert                                                                                           |


**applySnapshot 流程**：先更新 `itemLookup`（matchID → 顯示用 Model）→ 建立 Snapshot（item = matchID 陣列）→ 取出並清空 `pendingChanges` → 對有變動的 ID 呼叫 `reconfigureItems` → `dataSource.apply(snapshot)`；在 apply 的 completion 中對可見且變動的 cell 呼叫 `animateOddsHighlight(side:)`。因此 **先送 changes、再送 list**，VC 才能在同一輪 apply 裡同時更新數字與播放高亮。

**技術選擇**：用 **DiffableDataSource + reconfigureItems** 原地更新 cell 內容、不整頁 reload、不觸發 insert/delete 動畫；item identifier 用 `Int`（matchID）。

**逐批更新**：`OddsStreamService` 每次 tick 已將同一秒的推播打包為一個 `[Odds]` 陣列；ViewModel 的 `for await` loop 逐批處理，每批觸發一次 `applyUpdates + Subject send`，UI 更新頻率由 tick 間隔（1 秒）自然節流，無需額外 `collect(.byTime:)`。

---

## 加分項目

### WebSocket 斷線自動重連（Exponential Backoff）

`OddsStreamService`（actor）模擬每 15 秒斷線一次，內部以 `Task.sleep` 計時（取代 DispatchWorkItem），斷線時透過 `disconnectedContinuation.yield(())` 發出事件。ViewModel 的 `Task { for await _ in disconnectedStream { ... } }` 收到事件後呼叫 `repository.reconnectStream()`，重連延遲從 1 秒開始每次加倍（1s → 2s → 4s → 8s → 16s → 上限 30s），設定最大重連次數（10 次）防止無限重試。連線成功後延遲與次數自動重置。

ViewController 另外監聽 `willResignActive` / `didBecomeActive`，App 進入背景時暫停串流，回前景時自動恢復，節省背景資源。

### 快取

快取由獨立的 `OddsRepository` 持有，**`AppContainer`（Composition Root）** 建立並注入至 ViewModel。生命週期與 `AppContainer`（= Scene）綁定，而非與 ViewModel 綁定。

```
SceneDelegate
  └── AppContainer
        ├── apiService（MockAPIService）← struct，無狀態 value type
        └── repository（OddsRepository）← actor
              ├── apiService           ← REST 呼叫封裝在此
              ├── oddsStreamFactory    ← async factory（await MainActor.run 建立 OddsStreamService）
              ├── activeStream         ← 暴露 stream service，ViewModel 自行 await .updates / .disconnected
              ├── startStream / pauseStream / reconnectStream ← async 生命週期方法
              └── cachedList           ← in-memory 快取
        makeOddsListViewModel() → OddsListViewModel(repository:)
              → load() 呼叫 repository.fetchSnapshot() 取初始資料
              → 先 send repository.cachedList → 背景 REST 覆蓋 → 寫回 repository
```

ViewModel 只依賴 `OddsRepository`，是所有資料的唯一窗口（REST + WebSocket + cache）。Repository 持有串流 service 但不消費，只暴露 `activeStream` 讓 `@MainActor` ViewModel 自行 `await stream.updates` 並以 `Task + for await` 消費。ViewModel 只管 Subject 寫入與 UI 驅動。VC 因 push/pop 被 dealloc、ViewModel 隨之釋放（`oddsTask` / `disconnectTask` 自動取消），`AppContainer` 持有的 `repository` 仍然存活，重建 ViewModel 時快取依然有效。

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
│   ├── OddsHighlightSide.swift      ← 賠率變動方向（teamA / teamB / both, Sendable）
│   └── MatchCellModel.swift         ← 顯示用 Model / DTO（Identifiable, Sendable）
├── ViewModels/
│   └── OddsListViewModel.swift      ← @MainActor；Task+for-await 消費 AsyncStream、寫入 Subject、changesPublisher
├── ViewControllers/
│   └── OddsListViewController.swift ← DiffableDataSource、UI 綁定、pendingChanges 動畫、App 生命週期
├── Views/
│   ├── OddsListTableViewCell.swift  ← UI
│   └── FPSMonitor.swift             ← CADisplayLink FPS 即時監測（Debug 用）
├── Repositories/
│   └── OddsRepository.swift         ← actor；fetch + merge + sort + cache + applyUpdates + activeStream
└── Services/
    ├── MatchAPIServiceProtocol.swift ← REST 協定 + APIError（Sendable）；無 AnyObject constraint
    ├── MockAPIService.swift          ← struct；模擬 REST（100 筆），無狀態 value type
    └── OddsStreamService.swift       ← actor；AsyncStream + Continuation；Task.sleep loop + Exponential Backoff

OpenNetTests/
├── TestStubs.swift                  ← 共用 StubAPIService / StubStreamService / TestFixtures
├── OddsListViewModelTests.swift     ← 注入 stub 驗證 load / 串流更新 / changesPublisher / lifecycle
├── OddsRepositoryTests.swift        ← 直接測試 fetchSnapshot、applyUpdates highlight 判斷
└── MatchCellModelTests.swift        ← oddsChanged diff helper、Identifiable
```

---

## 測試

單元測試透過注入 stub service 驗證行為，所有測試方法均為 `async throws`，使用 `await fulfillment(of:timeout:)` 取代 timing hack。

`StubStreamService` 為 `final class`（`@unchecked Sendable`），內部持有 `AsyncStream.Continuation`，透過 `sendOddsUpdate(_:)` / `sendDisconnect()` 方法模擬推播事件，比 `PassthroughSubject` 更貼近生產程式碼的實際行為。`async` 協定方法由同步實作滿足（Swift 允許），測試端可直接同步讀取 `isStarted` / `isPaused` / `reconnectCount`。

- **OddsRepositoryTests**：直接對 `actor OddsRepository` 測試 `fetchSnapshot`（merge、sort、cache 寫入、API 失敗 throws、無賠率比賽略過）與 `applyUpdates`（teamA / teamB / both 變動、無變動、未知 matchID、空陣列）
- **OddsListViewModelTests**：注入 `StubAPIService` + `StubStreamService`，驗證初始載入合併排序、串流推播僅更新對應 matchID、`changesPublisher` 推送正確 highlight side、`load()` 重複呼叫不重複啟動串流、pause/reconnect 正確委派至 Repository
- **MatchCellModelTests**：`oddsChanged()` 各 branch（僅 A 變 / 僅 B 變 / 兩側都變 / 相同 / 不同 matchID）、`Identifiable` identity

---
