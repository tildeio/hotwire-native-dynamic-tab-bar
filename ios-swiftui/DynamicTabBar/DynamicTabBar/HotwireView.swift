//
//  HotwireView.swift
//  DynamicTabBar
//
//  Bridges Hotwire Native into SwiftUI.
//  Each tab owns a Navigator → WKWebView, wrapped in a stable container VC.
//

import SwiftUI
import HotwireNative

struct HotwireView: UIViewControllerRepresentable {
    let navigator: Navigator

    func makeUIViewController(context: Context) -> NavigatorContainer {
        NavigatorContainer(navigator: navigator)
    }

    func updateUIViewController(_ container: NavigatorContainer, context: Context) {
        container.update(navigator: navigator)
    }
}

/// Wraps Navigator.rootViewController as a UIKit child VC.
///
/// When tabs rearrange (Case 9 morph), SwiftUI may recreate the representable.
/// Without this container, both old and new hosting controllers target the same
/// rootViewController — the old one's viewDidDisappear fires after the new one's
/// viewWillAppear, deactivating the WebView (blank screen). Each hosting controller
/// gets its own NavigatorContainer, so stale lifecycle events from the old one
/// don't reach rootViewController.
class NavigatorContainer: UIViewController {
    private(set) var currentNavigator: Navigator?

    init(navigator: Navigator) {
        super.init(nibName: nil, bundle: nil)
        self.currentNavigator = navigator
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let navigator = currentNavigator {
            embedNavigator(navigator)
        }
    }

    func update(navigator: Navigator) {
        guard navigator !== currentNavigator else { return }
        removeCurrentChild()
        currentNavigator = navigator
        if isViewLoaded {
            embedNavigator(navigator)
        }
    }

    private func embedNavigator(_ navigator: Navigator) {
        navigator.start()
        let child = navigator.rootViewController
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(child.view)
        child.didMove(toParent: self)
    }

    private func removeCurrentChild() {
        for child in children {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
    }
}
