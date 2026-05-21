import Foundation
import FreeFlowKit
import WebKit

/// Handle messages from the onboarding web page running in WKWebView.
///
/// JavaScript calls `window.webkit.messageHandlers.freeflow.postMessage(data)`
/// where `data` is a JSON object with an `action` field. The bridge
/// dispatches each action to the registered handler closure.
///
/// To push events back to JavaScript, call `pushEvent(name:data:)` which
/// evaluates `window.freeflowbridge.onEvent(...)` in the web view.
///
/// Actions received from web pages:
///   - storeAPIKey: { action, data: { key } }
///   - checkAccessibility: { action }
///   - openAccessibilitySettings: { action }
///   - requestMicrophone: { action }
///   - listMicrophones: { action }
///   - selectMicrophone: { action, data: { id } }
///   - startMicPreview: { action }
///   - stopMicPreview: { action }
///   - registerHotkey: { action }
///   - completeOnboarding: { action }
///
/// Events pushed to web pages:
///   - apiKeyStoreResult: { event, error? }
///   - permissionStatus: { event, accessibility, microphone }
///   - microphoneList: { event, devices: [...], currentId }
///   - microphoneSelected: { event, id }
///   - audioLevel: { event, level }
///   - dictationResult: { event, text }
@MainActor
final class OnboardingBridge: NSObject, WKScriptMessageHandler {

    /// The web view to push events back to. Set by OnboardingController
    /// after the window is created.
    weak var webView: WKWebView?

    /// Handler closures for each bridge action. Set by OnboardingController
    /// to wire native services to web page requests.
    var onSetDictationMode: ((_ mode: String) -> Void)?
    var onStoreAPIKey: ((_ key: String) -> Void)?
    var onCheckAccessibility: (() -> Void)?
    var onOpenAccessibilitySettings: (() -> Void)?
    var onRequestMicrophone: (() -> Void)?
    var onListMicrophones: (() -> Void)?
    var onSelectMicrophone: ((_ id: UInt32) -> Void)?
    var onStartMicPreview: (() -> Void)?
    var onStopMicPreview: (() -> Void)?
    var onRegisterHotkey: (() -> Void)?
    var onCompleteOnboarding: (() -> Void)?

    // MARK: - WKScriptMessageHandler

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        Task { @MainActor in
            self.handleMessage(message)
        }
    }

    private func handleMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
            let action = body["action"] as? String
        else {
            return
        }

        // The JS bridge wraps payload fields inside a "data" key:
        //   bridge.send("storeAPIKey", { key: "sk-..." })
        // becomes { action: "storeAPIKey", data: { key: "sk-..." } }.
        let data = body["data"] as? [String: Any] ?? [:]

        switch action {
        case "setDictationMode":
            if let mode = data["mode"] as? String {
                onSetDictationMode?(mode)
            }

        case "storeAPIKey":
            if let key = data["key"] as? String {
                onStoreAPIKey?(key)
            }

        case "checkAccessibility":
            onCheckAccessibility?()

        case "openAccessibilitySettings":
            onOpenAccessibilitySettings?()

        case "requestMicrophone":
            onRequestMicrophone?()

        case "listMicrophones":
            onListMicrophones?()

        case "selectMicrophone":
            if let idNumber = data["id"] as? NSNumber {
                onSelectMicrophone?(idNumber.uint32Value)
            } else if let idInt = data["id"] as? Int {
                onSelectMicrophone?(UInt32(idInt))
            }

        case "startMicPreview":
            onStartMicPreview?()

        case "stopMicPreview":
            onStopMicPreview?()

        case "registerHotkey":
            onRegisterHotkey?()

        case "completeOnboarding":
            onCompleteOnboarding?()

        default:
            break
        }
    }

    // MARK: - Push events to JavaScript

    /// Push an event to the web page by calling
    /// `window.freeflowbridge.onEvent(data)`.
    func pushEvent(name: String, data: [String: Any] = [:]) {
        var payload = data
        payload["event"] = name

        guard
            let jsonData = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.fragmentsAllowed]
            ),
            let jsonString = String(data: jsonData, encoding: .utf8)
        else {
            return
        }

        let script = "window.freeflowbridge && window.freeflowbridge.onEvent(\(jsonString));"
        webView?.evaluateJavaScript(script) { _, error in
            if let error {
                Log.debug("[OnboardingBridge] pushEvent(\(name)) error: \(error)")
            }
        }
    }

    /// Push onboarding state with local mode availability, hardware,
    /// and language info so the welcome screen can set smart defaults.
    func pushOnboardingState() {
        let language = Settings.shared.language
        var data: [String: Any] = [
            "localModeAvailable": DictationMode.isLocalAvailable,
            "systemLanguage": language.languageCode,
            "systemLanguageName": language.displayName,
        ]
        #if arch(arm64)
        data["isAppleSilicon"] = true
        #else
        data["isAppleSilicon"] = false
        #endif
        pushEvent(name: "onboardingState", data: data)
    }

    /// Render SF Symbols to PNG data URIs and push to the web view.
    func pushStepIcons() {
        let symbols = [
            "key.viewfinder",
            "accessibility",
            "mic.circle",
            "mic.and.signal.meter",
            "text.redaction",
        ]
        let color = NSColor(red: 0x29 / 255.0, green: 0x29 / 255.0,
                            blue: 0x29 / 255.0, alpha: 1.0)
        let config = NSImage.SymbolConfiguration(
            pointSize: 28, weight: .regular
        ).applying(
            .init(paletteColors: [color])
        )

        var icons: [String: String] = [:]
        for name in symbols {
            guard let image = NSImage(
                systemSymbolName: name,
                accessibilityDescription: nil
            )?.withSymbolConfiguration(config) else { continue }

            // Render at 2x for Retina.
            let scale: CGFloat = 2
            let size = image.size
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * scale),
                pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
            guard let rep else { continue }
            rep.size = size

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(
                in: NSRect(origin: .zero, size: size),
                from: .zero, operation: .sourceOver, fraction: 1.0
            )
            NSGraphicsContext.restoreGraphicsState()

            if let png = rep.representation(using: .png, properties: [:]) {
                icons[name] = png.base64EncodedString()
            }
        }
        pushEvent(name: "stepIcons", data: icons)
    }

    /// Push an apiKeyStoreResult event (success or error).
    func pushAPIKeyStoreResult(error: String? = nil) {
        if let error {
            pushEvent(name: "apiKeyStoreResult", data: ["error": error])
        } else {
            pushEvent(name: "apiKeyStoreResult")
        }
    }

    /// Push a permissionStatus event.
    func pushPermissionStatus(accessibility: String, microphone: String) {
        pushEvent(
            name: "permissionStatus",
            data: [
                "accessibility": accessibility,
                "microphone": microphone,
            ])
    }

    /// Push a microphoneList event with available devices.
    func pushMicrophoneList(devices: [[String: Any]], currentId: UInt32?) {
        var data: [String: Any] = ["devices": devices]
        if let currentId {
            data["currentId"] = currentId
        }
        pushEvent(name: "microphoneList", data: data)
    }

    /// Push a microphoneSelected confirmation event.
    func pushMicrophoneSelected(id: UInt32) {
        pushEvent(name: "microphoneSelected", data: ["id": id])
    }

    /// Push an audioLevel event with the current RMS level.
    func pushAudioLevel(level: Float) {
        pushEvent(name: "audioLevel", data: ["level": level])
    }

    /// Push a dictationResult event.
    func pushDictationResult(text: String) {
        pushEvent(
            name: "dictationResult",
            data: [
                "text": text
            ])
    }
}
