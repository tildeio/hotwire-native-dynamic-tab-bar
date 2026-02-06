//
//  Notifications.swift
//  DynamicTabBar
//
//  Notification definitions for server-driven tab navigation
//

import Foundation

extension Notification.Name {
    /// Posted by NavigationComponent when server sends tab configuration
    static let tabConfigurationDidChange = Notification.Name("tabConfigurationDidChange")
}
