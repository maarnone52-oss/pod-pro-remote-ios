import UIKit
import WebKit
import CoreAudioKit

/// Mostra il pannello (Web/index.html) e collega la pagina al MIDI di iOS.
final class MainViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView!
    private let midi = MIDIBridge()
    private let panelColor = UIColor(red: 0.114, green: 0.118, blue: 0.129, alpha: 1)

    override func loadView() {
        let contentController = WKUserContentController()
        if let shimURL = Bundle.main.url(forResource: "midi-shim", withExtension: "js", subdirectory: "Web"),
           let shim = try? String(contentsOf: shimURL, encoding: .utf8) {
            contentController.addUserScript(
                WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        contentController.add(self, name: "midi")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController

        webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = panelColor
        webView.scrollView.backgroundColor = panelColor
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        view = webView

        midi.onEvent = { [weak self] event in self?.sendToPage(event) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") else { return }
        webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: - Dalla pagina all'app

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "init":
            midi.start()
        case "send":
            guard let id = body["id"] as? String, let values = body["data"] as? [Any] else { return }
            let bytes = values.compactMap { v -> UInt8? in
                guard let n = v as? NSNumber else { return nil }
                return UInt8(truncatingIfNeeded: n.intValue)
            }
            midi.send(to: id, bytes: bytes)
        case "save":
            guard let name = body["name"] as? String, let b64 = body["base64"] as? String,
                  let data = Data(base64Encoded: b64) else { return }
            shareFile(named: name, data: data)
        case "bluetooth":
            showBluetoothMIDI()
        default:
            break
        }
    }

    // MARK: - Dall'app alla pagina

    private func sendToPage(_ event: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: json, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__podMIDI && window.__podMIDI.receive(\(text));", completionHandler: nil)
    }

    // MARK: - Salvataggio file (backup ed esportazione preset)

    private func shareFile(named name: String, data: Data) {
        let safeName = name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
        do { try data.write(to: url, options: .atomic) } catch { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }

    // MARK: - Adattatori MIDI Bluetooth

    private func showBluetoothMIDI() {
        let central = CABTMIDICentralViewController()
        central.navigationItem.rightBarButtonItem =
            UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(closeBluetooth))
        let nav = UINavigationController(rootViewController: central)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    @objc private func closeBluetooth() {
        dismiss(animated: true) { [weak self] in self?.midi.refresh() }
    }

    // MARK: - Link esterni nel browser, non dentro l'app

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
        if url.isFileURL || url.scheme == "blob" || url.scheme == "about" || url.scheme == "data" {
            decisionHandler(.allow)
        } else {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        }
    }
}
