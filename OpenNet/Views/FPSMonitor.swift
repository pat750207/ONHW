//
//  FPSMonitor.swift
//  OpenNet
//
//  Created by Pat Chang on 2026/3/12.
//

import UIKit

/// CADisplayLink FPS 監測器。
/// 在畫面右上角疊加一個半透明 Label，即時顯示當前 FPS。
/// 僅供 Debug 用，展示高頻推播下 UI 仍能維持 60fps（或 ProMotion 120fps）。
final class FPSMonitor {

    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var frameCount: Int = 0

    private let label: UILabel = {
        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.textAlignment = .center
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        label.layer.cornerRadius = 6
        label.clipsToBounds = true
        label.text = "-- FPS"
        return label
    }()

    /// 將 FPS Label 加到指定 view 右上角，開始監測。
    func start(in view: UIView) {
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            label.widthAnchor.constraint(equalToConstant: 64),
            label.heightAnchor.constraint(equalToConstant: 24)
        ])

        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        label.removeFromSuperview()
    }

    @objc private func tick(_ link: CADisplayLink) {
        frameCount += 1

        if lastTimestamp == 0 {
            lastTimestamp = link.timestamp
            return
        }

        let elapsed = link.timestamp - lastTimestamp

        // 每 1 秒更新一次顯示
        guard elapsed >= 1.0 else { return }

        let fps = Double(frameCount) / elapsed
        frameCount = 0
        lastTimestamp = link.timestamp

        let fpsInt = Int(round(fps))
        label.text = "\(fpsInt) FPS"

        // 顏色回饋：綠色 ≥ 55、黃色 ≥ 40、紅色 < 40
        if fpsInt >= 55 {
            label.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.75)
        } else if fpsInt >= 40 {
            label.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.75)
        } else {
            label.backgroundColor = UIColor.systemRed.withAlphaComponent(0.75)
        }

        print("[FPS] \(fpsInt) fps")
    }
}
