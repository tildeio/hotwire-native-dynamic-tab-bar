//
//  AppDelegate.swift
//  DynamicTabBar
//
//  Hotwire setup: path configuration, bridge components, debug logging.
//  Maps to the inner AppDelegate class in the SwiftUI DynamicTabBarApp.swift.
//

import UIKit
import HotwireNative

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Load path configuration
        Hotwire.loadPathConfiguration(from: [
            .file(Bundle.main.url(forResource: "path-configuration", withExtension: "json")!),
            .server(URL(string: "http://localhost:3000/configurations/navigation.json")!),
        ])

        // Register bridge components
        Hotwire.registerBridgeComponents([
            NavigationComponent.self
        ])

        // Enable debug logging
        Hotwire.config.debugLoggingEnabled = true

        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}
