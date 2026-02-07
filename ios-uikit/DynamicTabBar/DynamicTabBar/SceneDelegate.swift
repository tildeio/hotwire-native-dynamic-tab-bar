//
//  SceneDelegate.swift
//  DynamicTabBar
//
//  Programmatic window creation with TabbedNavigator as root.
//  Maps to DynamicTabBarApp.body in the SwiftUI version.
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    private var tabManager: TabManager?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }

        let baseURL = URL(string: "http://localhost:3000")!
        let tabManager = TabManager()
        self.tabManager = tabManager

        let tabbedNavigator = TabbedNavigator(tabManager: tabManager, baseURL: baseURL)

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = tabbedNavigator
        window.makeKeyAndVisible()
        self.window = window
    }
}
