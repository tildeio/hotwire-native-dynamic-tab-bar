//
//  DynamicTabBarApp.swift
//  DynamicTabBar
//
//  Demo app for server-driven tab bar navigation.
//  Uses Hotwire Native bridge to receive tab configuration from the server.
//

import SwiftUI
import HotwireNative

@main
struct DynamicTabBarApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var tabManager = TabManager()

    let baseURL = URL(string: "http://localhost:3000")!

    var body: some Scene {
        WindowGroup {
            TabbedNavigator(tabManager: tabManager, baseURL: baseURL)
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    nonisolated func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
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
}
