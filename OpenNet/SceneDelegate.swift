//
//  SceneDelegate.swift
//  OpenNet
//
//  Created by Pat Chang on 2026/3/10.
//

import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

  var window: UIWindow?

  private let container = AppContainer()

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }

    // TODO: When adding multiple screens, extract to Coordinator 
    let viewModel = container.makeOddsListViewModel()
    let viewController = OddsListViewController(viewModel: viewModel)

    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = UINavigationController(rootViewController: viewController)
    window.makeKeyAndVisible()
    self.window = window
  }
}
