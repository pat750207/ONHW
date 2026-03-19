//
//  OddsListTableViewCell.swift
//  OpenNet
//
//  Created by Pat Chang on 2026/3/10.
//

import UIKit

/// ```
/// ┌──────────────────────────────────────────┐
/// │  TeamA vs TeamB          TeamA    TeamB  │
/// │  3/10, 8:00 PM            1.50     2.30  │
/// └──────────────────────────────────────────┘
/// ```


final class OddsListTableViewCell: UITableViewCell {

    static let reuseId = "OddsListTableViewCell"

    private static let displayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        return fmt
    }()

    private let matchTitleLabel: UILabel = {
        let lbl = UILabel()
        lbl.font = .preferredFont(forTextStyle: .headline)
        lbl.adjustsFontForContentSizeCategory = true
        lbl.numberOfLines = 1
        return lbl
    }()

    private let timeLabel: UILabel = {
        let lbl = UILabel()
        lbl.font = .preferredFont(forTextStyle: .subheadline)
        lbl.adjustsFontForContentSizeCategory = true
        lbl.textColor = .secondaryLabel
        return lbl
    }()

    private let teamANameLabel: UILabel = {
        let lbl = UILabel()
        lbl.font = .preferredFont(forTextStyle: .caption1)
        lbl.adjustsFontForContentSizeCategory = true
        lbl.textColor = .secondaryLabel
        lbl.textAlignment = .center
        return lbl
    }()

    private let teamBNameLabel: UILabel = {
        let lbl = UILabel()
        lbl.font = .preferredFont(forTextStyle: .caption1)
        lbl.adjustsFontForContentSizeCategory = true
        lbl.textColor = .secondaryLabel
        lbl.textAlignment = .center
        return lbl
    }()

    private let teamAOddsLabel: UILabel = {
        let lbl = UILabel()
        lbl.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        lbl.textAlignment = .center
        return lbl
    }()

    private let teamBOddsLabel: UILabel = {
        let lbl = UILabel()
        lbl.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        lbl.textAlignment = .center
        return lbl
    }()

    private let oddsContainer: UIStackView = {
        let sv = UIStackView()
        sv.axis = .vertical
        sv.alignment = .fill
        sv.distribution = .fill
        sv.spacing = 2
        return sv
    }()

    private let namesRow: UIStackView = {
        let sv = UIStackView()
        sv.axis = .horizontal
        sv.alignment = .fill
        sv.distribution = .fillEqually
        sv.spacing = 12
        return sv
    }()

    private let oddsRow: UIStackView = {
        let sv = UIStackView()
        sv.axis = .horizontal
        sv.alignment = .fill
        sv.distribution = .fillEqually
        sv.spacing = 12
        return sv
    }()

    private let highlightViewA: UIView = {
        let v = UIView()
        v.backgroundColor = .clear
        v.layer.cornerRadius = 5
        v.isUserInteractionEnabled = false
        return v
    }()

    private let highlightViewB: UIView = {
        let v = UIView()
        v.backgroundColor = .clear
        v.layer.cornerRadius = 5
        v.isUserInteractionEnabled = false
        return v
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        setupLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupLayout() {
        namesRow.addArrangedSubview(teamANameLabel)
        namesRow.addArrangedSubview(teamBNameLabel)
        oddsRow.addArrangedSubview(teamAOddsLabel)
        oddsRow.addArrangedSubview(teamBOddsLabel)
        oddsContainer.addArrangedSubview(namesRow)
        oddsContainer.addArrangedSubview(oddsRow)

        contentView.addSubview(highlightViewA)
        contentView.addSubview(highlightViewB)
        contentView.addSubview(matchTitleLabel)
        contentView.addSubview(timeLabel)
        contentView.addSubview(oddsContainer)

        [matchTitleLabel, timeLabel, oddsContainer,
         highlightViewA, highlightViewB].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            // 左側：比賽標題
            matchTitleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            matchTitleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            matchTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: oddsContainer.leadingAnchor, constant: -12),

            // 左側：開賽時間
            timeLabel.topAnchor.constraint(equalTo: matchTitleLabel.bottomAnchor, constant: 4),
            timeLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            timeLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -12),

            // 右側：賠率區（垂直置中）
            oddsContainer.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            oddsContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            oddsContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            // highlightViewA：對齊 teamANameLabel 欄位（上下跟 oddsContainer 齊）
            highlightViewA.topAnchor.constraint(equalTo: oddsContainer.topAnchor, constant: -4),
            highlightViewA.bottomAnchor.constraint(equalTo: oddsContainer.bottomAnchor, constant: 4),
            highlightViewA.leadingAnchor.constraint(equalTo: teamANameLabel.leadingAnchor, constant: -6),
            highlightViewA.trailingAnchor.constraint(equalTo: teamANameLabel.trailingAnchor, constant: 6),

            // highlightViewB：對齊 teamBNameLabel 欄位（上下跟 oddsContainer 齊）
            highlightViewB.topAnchor.constraint(equalTo: oddsContainer.topAnchor, constant: -4),
            highlightViewB.bottomAnchor.constraint(equalTo: oddsContainer.bottomAnchor, constant: 4),
            highlightViewB.leadingAnchor.constraint(equalTo: teamBNameLabel.leadingAnchor, constant: -6),
            highlightViewB.trailingAnchor.constraint(equalTo: teamBNameLabel.trailingAnchor, constant: 6),
        ])

        oddsContainer.setContentHuggingPriority(.required, for: .horizontal)
        oddsContainer.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    ///  - item: 比賽 + 賠率資料
    ///  - highlightSide: 需要高亮的欄位方向，`nil` 表示不播放動畫。

    func configure(with item: MatchSummary, highlightSide: OddsHighlightSide? = nil) {
        matchTitleLabel.text = "\(item.teamA) vs \(item.teamB)"
        timeLabel.text = Self.formatTime(item.startTime)

        teamANameLabel.text = item.teamA
        teamBNameLabel.text = item.teamB
        teamAOddsLabel.text = String(format: "%.2f", item.teamAOdds)
        teamBOddsLabel.text = String(format: "%.2f", item.teamBOdds)

        accessibilityLabel = "\(item.teamA) 對 \(item.teamB)"
        accessibilityValue = "\(item.teamA) 賠率 \(String(format: "%.2f", item.teamAOdds))，\(item.teamB) 賠率 \(String(format: "%.2f", item.teamBOdds))"

        if let side = highlightSide {
            animateOddsHighlight(side: side)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        highlightViewA.backgroundColor = .clear
        highlightViewA.layer.removeAllAnimations()
        highlightViewB.backgroundColor = .clear
        highlightViewB.layer.removeAllAnimations()
    }

    func animateOddsHighlight(side: OddsHighlightSide) {
        switch side {
        case .teamA:
            animateHighlightView(highlightViewA)
        case .teamB:
            animateHighlightView(highlightViewB)
        case .both:
            animateHighlightView(highlightViewA)
            animateHighlightView(highlightViewB)
        }
    }
    
    /// ViewController 在 `apply(completion:)` 中呼叫，確保 snapshot 生效後才觸發，避免 cell provider 非同步時序導致動畫遺失。
    private func animateHighlightView(_ view: UIView) {
        view.backgroundColor = UIColor.systemRed.withAlphaComponent(0.15)
        UIView.animate(withDuration: 0.6, delay: 0.1, options: [.curveEaseOut, .allowUserInteraction]) {
            view.backgroundColor = .clear
        }
    }

    private static func formatTime(_ date: Date) -> String {
        displayFormatter.string(from: date)
    }
}
