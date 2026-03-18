//
//  OddsListViewController.swift
//  OpenNet
//
//  Created by Pat Chang on 2026/3/11.
//

@preconcurrency import Combine
@preconcurrency import UIKit

// for DiffableDataSource
enum OddsListSection: Int, Hashable, Sendable, CaseIterable {
    case main
}

final class OddsListViewController: UIViewController {

    // Item identifier 使用 Int (matchID)
    private typealias DataSource = UITableViewDiffableDataSource<OddsListSection, Int>
    private typealias Snapshot = NSDiffableDataSourceSnapshot<OddsListSection, Int>

    private let tableView = UITableView(frame: .zero, style: .plain)
    private var dataSource: DataSource!
    private let viewModel: OddsListViewModel
    private var cancellables = Set<AnyCancellable>()

    private var itemLookup: [Int: MatchCellModel] = [:]

    private var pendingChanges: [Int: OddsHighlightSide] = [:]

    private let fpsMonitor = FPSMonitor()

    init(viewModel: OddsListViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "即時賽事賠率"
        view.backgroundColor = .systemBackground
        setupTableView()
        setupDiffableDataSource()
        bindViewModel()
        viewModel.load()
        observeAppLifecycle()
        fpsMonitor.start(in: view)
    }

    private func setupTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        tableView.register(OddsListTableViewCell.self, forCellReuseIdentifier: OddsListTableViewCell.reuseId)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
    }

    private func setupDiffableDataSource() {
        dataSource = DataSource(tableView: tableView) { [weak self] tableView, indexPath, matchID in
            let cell = tableView.dequeueReusableCell(
                withIdentifier: OddsListTableViewCell.reuseId,
                for: indexPath
            ) as! OddsListTableViewCell
            if let self, let item = self.itemLookup[matchID] {
                cell.configure(with: item, highlightSide: nil)
            }
            return cell
        }
        tableView.dataSource = dataSource
    }

    private func bindViewModel() {
        viewModel.listPublisher
            .sink { [weak self] items in
                self?.applySnapshot(with: items)
            }
            .store(in: &cancellables)
        
        viewModel.changesPublisher
            .sink { [weak self] changes in
                self?.pendingChanges = changes
            }
            .store(in: &cancellables)

        viewModel.errorPublisher
            .sink { [weak self] error in
                self?.showError(error)
            }
            .store(in: &cancellables)
    }

    // 1. 更新 itemLookup（matchID → MatchCellModel）
    // 2. 建立 snapshot（item = matchID 陣列）
    // 3. 若 pendingChanges 有值 → reconfigureItems
    // 4. apply snapshot → completion do highlight
    private func applySnapshot(with items: [MatchCellModel]) {
        // 1. 更新 lookup table
        itemLookup = Dictionary(items.map { ($0.matchID, $0) }, uniquingKeysWith: { _, new in new })

        // 2. 建立 snapshot（item identifier = matchID）
        let matchIDs = items.map(\.matchID)
        var snapshot = Snapshot()
        snapshot.appendSections([.main])
        snapshot.appendItems(matchIDs)

        // 3. pendingChanges
        let changedIDMap = pendingChanges
        pendingChanges = [:]

        if !changedIDMap.isEmpty {
            let changedIDs = Array(changedIDMap.keys)
            print("[VC] reconfigure \(changedIDs.count) 筆 \(changedIDs)")
            snapshot.reconfigureItems(changedIDs)
        }

        // 4. Apply snapshot（計時 latency）
        let startTime = CACurrentMediaTime()

        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            let endTime = CACurrentMediaTime()
            let latencyMs = (endTime - startTime) * 1000
            print("[VC] Snapshot applied in: \(String(format: "%.2f", latencyMs))ms")

            guard let self, !changedIDMap.isEmpty else { return }

            var highlightCount = 0
            for cell in self.tableView.visibleCells {
                guard let oddsCell = cell as? OddsListTableViewCell,
                      let indexPath = self.tableView.indexPath(for: cell),
                      let matchID = self.dataSource.itemIdentifier(for: indexPath),
                      let side = changedIDMap[matchID]
                else { continue }
                oddsCell.animateOddsHighlight(side: side)
                highlightCount += 1
            }
            print("[VC] highlight 動畫 \(highlightCount) 筆")
        }
    }

    private func showError(_ error: APIError) {
        let message: String
        switch error {
        case .networkFailed: message = "網路連線失敗"
        case .decodingFailed: message = "資料解析失敗"
        case .serverError(let code): message = "伺服器錯誤（\(code)）"
        }
        let alert = UIAlertController(title: "載入失敗", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "重試", style: .default) { [weak self] _ in
            self?.viewModel.load()
        })
        alert.addAction(UIAlertAction(title: "確定", style: .cancel))
        present(alert, animated: true)
    }

    // 暫停/啟動監聽 odds with lifecycle
    private func observeAppLifecycle() {
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                Task { await self?.viewModel.pauseStream() }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { await self?.viewModel.reconnectStream() }
            }
            .store(in: &cancellables)
    }
}
