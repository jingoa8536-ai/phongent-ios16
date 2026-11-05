import SwiftUI
import WebKit

struct AoraAnimatedAvatar: UIViewRepresentable {
    var phase: String
    var active: Bool
    var shape: String = "blob"
    var hue:Double?=nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false; view.backgroundColor = .clear; view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false; view.navigationDelegate = context.coordinator
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Aora") { view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.hue = hue
        context.coordinator.id = AoraEmotion.id(for: phase)
        context.coordinator.shape = ["blob","wedge","gem"].contains(shape) ? shape:"blob"
        context.coordinator.active = active && !reduceMotion
        context.coordinator.apply(view)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { view.evaluateJavaScript("window.destroyMika()", completionHandler: nil); view.stopLoading() }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var shape="blob"
        var hue:Double?
        var id = "02"; var active = true; var ready = false; var last = ""
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; apply(webView) }
        func apply(_ view: WKWebView) {
            let signature = id + String(active) + shape + String(describing:hue); guard ready, signature != last else { return }; last = signature
            let filter=hue.map{"sepia(1) saturate(2) hue-rotate(\($0)deg) brightness(0.84)"} ?? "saturate(0.85) brightness(0.84)"
            view.evaluateJavaScript("document.getElementById('bot').style.filter='\(filter)';window.setMikaShape('\(shape)');window.setMikaState('\(id)',\(active ? "true" : "false"))", completionHandler: nil)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel) }
    }
}
