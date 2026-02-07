//
//  NavigationComponent.swift
//  DynamicTabBar
//
//  Bridge component for server-driven tab navigation.
//  Receives 'configure' messages from Rails and updates tab state.
//

import Foundation
import HotwireNative
import os.log

// MARK: - NavigationComponent

final class NavigationComponent: BridgeComponent {
    private let logger = Logger(subsystem: "com.example.dynamictabbar", category: "NavigationComponent")

    nonisolated override class var name: String { "navigation" }

    override func onReceive(message: Message) {
        guard message.event == "configure" else {
            logger.warning("Received unknown event: \(message.event)")
            return
        }

        // Decode the message data
        guard let data: MessageData = message.data() else {
            logger.error("Failed to decode message data")
            return
        }

        // Build directive from message data
        let directive: TabsDirective
        if data.tabs.isEmpty {
            directive = .bootstrap
        } else if let active = data.active {
            directive = .tabbed(active: active, tabs: data.tabs)
        } else {
            logger.error("Protocol violation: non-empty tabs without active field")
            return
        }

        // Post notification to TabbedNavigator
        NotificationCenter.default.post(
            name: .tabConfigurationDidChange,
            object: nil,
            userInfo: ["directive": directive]
        )

        let tabCount = directive.tabs.count
        let mode = tabCount == 0 ? "Bootstrap" : "Tabbed(\(tabCount))"
        logger.info("Sent tab config: \(mode)")
    }
}

// MARK: - Message Data

private extension NavigationComponent {
    struct MessageData: Codable {
        let active: String?
        let tabs: [TabData]
    }
}
