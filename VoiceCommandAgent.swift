import AppKit
import AVFoundation
import ApplicationServices
import Speech

@MainActor
final class VoiceCommandAgent: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let audioEngine = AVAudioEngine()
    private let requestLock = NSLock()

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionGeneration = 0
    private var debounceWorkItem: DispatchWorkItem?
    private var lastTranscriptUpdate: Date?
    private var handledCurrentUtterance = false
    private var microphoneGranted: Bool?
    private var speechGranted: Bool?
    private var listening = false
    private var tapInstalled = false
    private var statusText = "Starting"

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        startListening()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        toggleListening()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        toggleListening()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusItem()
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu(from: sender)
        } else {
            toggleListening()
        }
    }

    private func showStatusMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        let state = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: listening ? "Stop Listening" : "Start Listening",
            action: #selector(toggleFromMenu),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Voice Command Agent",
            action: #selector(quit),
            keyEquivalent: "q"
        ).target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    @objc private func toggleFromMenu() {
        toggleListening()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let symbol = listening ? "mic.fill" : "mic.slash"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: statusText)
        button.toolTip = "Voice Command Agent: \(statusText). Click to toggle; right-click for options."
        button.setAccessibilityLabel("Voice Command Agent: \(statusText)")
    }

    private func setStatus(_ text: String) {
        statusText = text
        updateStatusItem()
    }

    private func toggleListening() {
        if listening {
            stopListening(status: "Stopped")
        } else {
            startListening()
        }
    }

    private func startListening() {
        guard !listening else { return }
        listening = true
        microphoneGranted = nil
        speechGranted = nil
        setStatus("Requesting microphone and speech access")
        requestPermissions()
    }

    private func requestPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneGranted = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.microphoneGranted = granted
                    self?.completePermissionChecks()
                }
            }
        case .denied, .restricted:
            microphoneGranted = false
        @unknown default:
            microphoneGranted = false
        }

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            speechGranted = true
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    self?.speechGranted = status == .authorized
                    self?.completePermissionChecks()
                }
            }
        case .denied, .restricted:
            speechGranted = false
        @unknown default:
            speechGranted = false
        }
        completePermissionChecks()
    }

    private func completePermissionChecks() {
        guard listening, let microphoneGranted, let speechGranted else { return }
        guard microphoneGranted && speechGranted else {
            stopListening(status: "Access denied; allow Microphone and Speech Recognition in System Settings")
            return
        }
        beginAudioCapture()
    }

    private func beginAudioCapture() {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            stopListening(status: "Speech recognition is unavailable")
            return
        }
        speechRecognizer = recognizer

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            stopListening(status: "No microphone input is available")
            return
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.requestLock.lock()
            let request = self.recognitionRequest
            self.requestLock.unlock()
            request?.append(buffer)
        }
        tapInstalled = true

        do {
            audioEngine.prepare()
            try audioEngine.start()
            startRecognitionTask()
            setStatus("Listening")
        } catch {
            stopListening(status: "Could not start microphone: \(error.localizedDescription)")
        }
    }

    private func startRecognitionTask() {
        guard listening, let speechRecognizer else { return }
        recognitionGeneration += 1
        let generation = recognitionGeneration
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        requestLock.lock()
        recognitionRequest = request
        requestLock.unlock()
        lastTranscriptUpdate = nil
        handledCurrentUtterance = false

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self,
                      self.listening,
                      self.recognitionGeneration == generation else { return }
                if let result {
                    self.receiveTranscript(
                        result.bestTranscription.formattedString,
                        isFinal: result.isFinal
                    )
                }
                if error != nil || result?.isFinal == true {
                    self.restartRecognitionTask()
                }
            }
        }
    }

    private func receiveTranscript(_ transcript: String, isFinal: Bool) {
        let now = Date()
        if let lastTranscriptUpdate, now.timeIntervalSince(lastTranscriptUpdate) > 1.8 {
            handledCurrentUtterance = false
        }
        lastTranscriptUpdate = now
        guard !handledCurrentUtterance else { return }

        debounceWorkItem?.cancel()
        if isFinal {
            processCommand(transcript)
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.processCommand(transcript)
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: workItem)
    }

    private func restartRecognitionTask() {
        recognitionGeneration += 1
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        requestLock.lock()
        recognitionRequest = nil
        requestLock.unlock()
        debounceWorkItem?.cancel()
        let generation = recognitionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.listening, self.recognitionGeneration == generation else { return }
            self.startRecognitionTask()
        }
    }

    private func processCommand(_ transcript: String) {
        guard let command = VoiceCommand.parse(transcript) else { return }
        handledCurrentUtterance = true
        switch command {
        case .open(let name):
            openApplication(named: name)
        case .search(let query):
            searchWeb(for: query)
        case .searchInApplication(let query, let applicationName):
            searchInApplication(query, named: applicationName)
        case .type(let text):
            typeText(text)
        case .view(let chatName):
            viewWhatsAppChat(named: chatName)
        }
    }

    private func openApplication(named name: String) {
        guard let appURL = findApplication(named: name) else {
            setStatus("Application not found: \(name)")
            return
        }
        setStatus("Opening \(name)")
        NSWorkspace.shared.openApplication(
            at: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error {
                    self?.setStatus("Could not open \(name): \(error.localizedDescription)")
                } else {
                    self?.setStatus("Opened \(name)")
                }
            }
        }
    }

    private func findApplication(named target: String) -> URL? {
        let fileManager = FileManager.default
        let searchRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        let soughtName = target.trimmingCharacters(in: .whitespacesAndNewlines)
        var matches: [(url: URL, name: String)] = []

        for root in searchRoots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "app" {
                let fileName = url.deletingPathExtension().lastPathComponent
                let bundleName = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? fileName
                let name = bundleName.trimmingCharacters(in: .whitespacesAndNewlines)
                if name.localizedCaseInsensitiveCompare(soughtName) == .orderedSame
                    || fileName.localizedCaseInsensitiveCompare(soughtName) == .orderedSame {
                    return url
                }
                if name.localizedCaseInsensitiveContains(soughtName)
                    || fileName.localizedCaseInsensitiveContains(soughtName) {
                    matches.append((url, name))
                }
            }
        }
        return matches.min { $0.name.count < $1.name.count }?.url
    }

    private func searchWeb(for query: String) {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url, NSWorkspace.shared.open(url) else {
            setStatus("Could not open a web search for: \(query)")
            return
        }
        setStatus("Searching for: \(query)")
    }

    private func searchInApplication(_ query: String, named name: String) {
        guard let appURL = findApplication(named: name) else {
            setStatus("Application not found: \(name)")
            return
        }
        guard accessibilityIsEnabled() else {
            setStatus("Allow Accessibility access in System Settings, then try again")
            return
        }
        setStatus("Searching in \(name)")
        NSWorkspace.shared.openApplication(
            at: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.setStatus("Could not open \(name): \(error.localizedDescription)")
                    return
                }
                self.runAppleScript(
                    """
                    delay 0.4
                    tell application "System Events"
                        keystroke "f" using {command down}
                        delay 0.25
                        keystroke \(self.appleScriptString(query))
                        keystroke return
                    end tell
                    """,
                    successStatus: "Searched in \(name)",
                    failurePrefix: "Could not search in \(name)"
                )
            }
        }
    }

    private func typeText(_ text: String) {
        guard accessibilityIsEnabled() else {
            setStatus("Allow Accessibility access in System Settings, then try again")
            return
        }
        setStatus("Typing message")
        runAppleScript(
            """
            tell application "System Events"
                keystroke \(appleScriptString(text))
            end tell
            """,
            successStatus: "Typed message (not sent)",
            failurePrefix: "Could not type message"
        )
    }

    private func viewWhatsAppChat(named chatName: String) {
        guard findApplication(named: "WhatsApp") != nil else {
            setStatus("WhatsApp is not installed")
            return
        }
        guard accessibilityIsEnabled() else {
            setStatus("Allow Accessibility access in System Settings, then try again")
            return
        }
        setStatus("Opening WhatsApp chat: \(chatName)")
        runAppleScript(
            """
            tell application "WhatsApp" to activate
            delay 0.5
            tell application "System Events"
                keystroke "f" using {command down}
                delay 0.3
                keystroke \(appleScriptString(chatName))
                delay 0.6
                keystroke return
            end tell
            """,
            successStatus: "Opened WhatsApp chat: \(chatName)",
            failurePrefix: "Could not open WhatsApp chat"
        )
    }

    private func accessibilityIsEnabled() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func runAppleScript(
        _ source: String,
        successStatus: String,
        failurePrefix: String
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var errorInfo: NSDictionary?
            guard let script = NSAppleScript(source: source) else {
                DispatchQueue.main.async {
                    self?.setStatus("\(failurePrefix): could not prepare automation")
                }
                return
            }
            _ = script.executeAndReturnError(&errorInfo)
            DispatchQueue.main.async {
                if let errorInfo {
                    let detail = errorInfo[NSAppleScript.errorMessage] as? String ?? "Automation was denied"
                    self?.setStatus("\(failurePrefix): \(detail)")
                } else {
                    self?.setStatus(successStatus)
                }
            }
        }
    }

    private func appleScriptString(_ text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        return lines.map { line in
            let escaped = line
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }.joined(separator: " & return & ")
    }

    private func stopListening(status: String) {
        listening = false
        recognitionGeneration += 1
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        requestLock.lock()
        recognitionRequest = nil
        requestLock.unlock()
        speechRecognizer = nil

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        setStatus(status)
    }
}

private enum VoiceCommand {
    case open(String)
    case search(String)
    case searchInApplication(String, String)
    case type(String)
    case view(String)

    static func parse(_ transcript: String) -> VoiceCommand? {
        let phrase = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return nil }
        let lowercased = phrase.lowercased()
        if lowercased.hasPrefix("search ") {
            let payload = String(phrase.dropFirst("search ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = payload.range(of: " in ", options: [.caseInsensitive, .backwards]) {
                let query = trimCommandPayload(String(payload[..<range.lowerBound]))
                let applicationName = trimCommandPayload(String(payload[range.upperBound...]))
                if !query.isEmpty && !applicationName.isEmpty {
                    return .searchInApplication(query, applicationName)
                }
            }
            let searchablePayload = trimCommandPayload(payload)
            return searchablePayload.isEmpty ? nil : .search(searchablePayload)
        }
        for (prefix, makeCommand) in [
            ("open ", VoiceCommand.open as (String) -> VoiceCommand),
            ("type ", VoiceCommand.type),
            ("view ", VoiceCommand.view)
        ] {
            guard lowercased.hasPrefix(prefix) else { continue }
            var payload = trimCommandPayload(String(phrase.dropFirst(prefix.count)))
            if prefix == "view ", payload.lowercased().hasSuffix(" chat") {
                payload = String(payload.dropLast(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !payload.isEmpty else { return nil }
            return makeCommand(payload)
        }
        return nil
    }

    private static func trimCommandPayload(_ value: String) -> String {
        var payload = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = payload.last, ".,!?".contains(last) {
            payload.removeLast()
        }
        return payload.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@main
@MainActor
enum VoiceCommandAgentMain {
    static func main() {
        let application = NSApplication.shared
        let agent = VoiceCommandAgent()
        application.setActivationPolicy(.accessory)
        application.delegate = agent
        application.run()
    }
}
