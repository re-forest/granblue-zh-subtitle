import SwiftUI
import UIKit
import WebKit

/// Mobage / DMM / Google 登入彈出視窗請求，持有系統傳入共享 Session 的 WKWebView 實例
struct IdentifiablePopupRequest: Identifiable {
    let id = UUID()
    let webView: WKWebView
}

/// 避免 WKUserContentController 對訊息處理者產生強參考循環
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// 主遊戲 WKWebView 封裝
struct GBFWebView: UIViewRepresentable {
    static let safariUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
    static let bridgeName = "subtitleBridge"

    @ObservedObject var sessionManager: SubtitleSessionManager

    func makeCoordinator() -> Coordinator {
        Coordinator(sessionManager: sessionManager)
    }

    func makeUIView(context: Context) -> WKWebView {
        let userContentController = WKUserContentController()
        let weakHandler = WeakScriptMessageHandler(context.coordinator)
        userContentController.add(weakHandler, name: Self.bridgeName)

        if let scriptURL = Bundle.main.url(forResource: "content-ios", withExtension: "js"),
           let source = try? String(contentsOf: scriptURL, encoding: .utf8) {
            let userScript = WKUserScript(
                source: source,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            userContentController.addUserScript(userScript)
        }

        let config = WKWebViewConfiguration()
        config.userContentController = userContentController
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.safariUserAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 7 / 255, green: 21 / 255, blue: 25 / 255, alpha: 1)

        context.coordinator.mainWebView = webView
        context.coordinator.bindWebActions()

        webView.load(URLRequest(url: SubtitleSessionManager.defaultGameURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 狀態變更皆透過註冊的控制動作與 Coordinator 處理
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: bridgeName)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        private let sessionManager: SubtitleSessionManager
        weak var mainWebView: WKWebView?
        private weak var activePopupWebView: WKWebView?

        init(sessionManager: SubtitleSessionManager) {
            self.sessionManager = sessionManager
            super.init()
        }

        func bindWebActions() {
            sessionManager.registerWebActions(
                reload: { [weak self] in
                    self?.mainWebView?.reload()
                },
                goBack: { [weak self] in
                    guard let webView = self?.mainWebView, webView.canGoBack else { return }
                    webView.goBack()
                },
                goHome: { [weak self] in
                    self?.mainWebView?.load(URLRequest(url: SubtitleSessionManager.defaultGameURL))
                },
                forceCheck: { [weak self] in
                    self?.mainWebView?.evaluateJavaScript("window.__gbfSubtitleBridge?.forceCheck?.()", completionHandler: nil)
                }
            )
        }

        // MARK: - WKScriptMessageHandler
        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == GBFWebView.bridgeName else { return }
            let body = message.body
            Task { @MainActor [weak self] in
                self?.sessionManager.handleBridgePayload(body)
            }
        }

        // MARK: - WKNavigationDelegate
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            guard webView === mainWebView else { return }
            syncNavigationState(webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard webView === mainWebView else { return }
            syncNavigationState(webView)
            webView.evaluateJavaScript("window.__gbfSubtitleBridge?.forceCheck?.()", completionHandler: nil)
        }

        private func syncNavigationState(_ webView: WKWebView) {
            sessionManager.canGoBack = webView.canGoBack
            sessionManager.canGoForward = webView.canGoForward
            if let title = webView.title, !title.isEmpty {
                sessionManager.pageTitle = title
            }
            if let url = webView.url {
                sessionManager.currentPageURL = url
            }
        }

        // MARK: - WKUIDelegate（支援 Mobage / DMM / Google 登入新視窗與 JS 對話框）
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil || !(navigationAction.targetFrame?.isMainFrame ?? true) else {
                return nil
            }
            // 必須直接以系統提供的 configuration 建立 WKWebView 並回傳，以保持 window.opener 與 Cookie 關聯
            let popup = WKWebView(frame: .zero, configuration: configuration)
            popup.customUserAgent = GBFWebView.safariUserAgent
            popup.uiDelegate = self
            popup.navigationDelegate = self
            activePopupWebView = popup
            sessionManager.popupWebViewConfiguration = IdentifiablePopupRequest(webView: popup)
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            if webView === activePopupWebView {
                activePopupWebView = nil
                sessionManager.popupWebViewConfiguration = nil
                mainWebView?.evaluateJavaScript("window.__gbfSubtitleBridge?.forceCheck?.()", completionHandler: nil)
            }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            presentAlert(title: "提示", message: message, includeCancel: false, textPlaceholder: nil) { _, _ in
                completionHandler()
            }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            presentAlert(title: "確認", message: message, includeCancel: true, textPlaceholder: nil) { confirmed, _ in
                completionHandler(confirmed)
            }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            presentAlert(title: "輸入", message: prompt, includeCancel: true, textPlaceholder: defaultText ?? "") { confirmed, text in
                completionHandler(confirmed ? text : nil)
            }
        }

        private func presentAlert(
            title: String,
            message: String,
            includeCancel: Bool,
            textPlaceholder: String?,
            completion: @escaping (Bool, String?) -> Void
        ) {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                  let root = (scene.keyWindow ?? scene.windows.first)?.rootViewController else {
                completion(false, nil)
                return
            }
            var presenter = root
            while let next = presenter.presentedViewController {
                presenter = next
            }

            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            if let placeholder = textPlaceholder {
                alert.addTextField { field in
                    field.text = placeholder
                }
            }
            if includeCancel {
                alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
                    completion(false, nil)
                })
            }
            alert.addAction(UIAlertAction(title: "確定", style: .default) { _ in
                completion(true, alert.textFields?.first?.text)
            })
            presenter.present(alert, animated: true)
        }
    }
}

/// 呈現在 Sheet 中的登入彈出層 WKWebView
struct PopupWebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 內容由主 Coordinator 與系統事件管理
    }
}
