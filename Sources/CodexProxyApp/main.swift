import AppKit
import CodexProxyCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SettingsStore()
    private let logger = ProxyLogger()
    private let oauthService = CodexOAuthService()
    private let rateLimitService = CodexRateLimitService()
    private let modelsService = CodexModelsService()
    private lazy var server = CodexProxyServer(logger: logger, oauthService: oauthService)
    private lazy var model = AppModel(store: store, server: server, logger: logger, oauthService: oauthService, rateLimitService: rateLimitService, modelsService: modelsService)
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        model.start()
        model.refreshOAuthIfNeeded()
        model.refreshRateLimits()
        model.refreshModels()
        rebuildMenu()

        model.onChange = { [weak self] in
            DispatchQueue.main.async {
                self?.rebuildMenu()
            }
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            if let image = trayIconImage() {
                button.image = image
            } else {
                button.title = "Codex"
            }
            button.imagePosition = .imageOnly
        }
        statusItem = item
    }

    private func trayIconImage() -> NSImage? {
        let image = NSImage(named: NSImage.Name("TrayIcon")) ??
            Bundle.main.url(forResource: "TrayIcon", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        image?.accessibilityDescription = "CodexAPI"
        return image
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let status = model.status

        menu.addItem(makeRateLimitsMenuItem())
        let refreshLimitsItem = makeMenuItem(model.isRefreshingRateLimits ? "Refreshing Limits..." : "Refresh Limits", action: #selector(refreshRateLimits))
        refreshLimitsItem.isEnabled = !model.isRefreshingRateLimits
        menu.addItem(refreshLimitsItem)
        menu.addItem(makeModelsMenuItem())

        menu.addItem(NSMenuItem.separator())
        if status.isRunning {
            menu.addItem(makeMenuItem("Stop Proxy", action: #selector(stopProxy)))
        } else {
            menu.addItem(makeMenuItem("Start Proxy", action: #selector(startProxy)))
        }
        menu.addItem(makeMenuItem("Restart Proxy", action: #selector(restartProxy), keyEquivalent: "r"))
        menu.addItem(makeMenuItem("Copy Base URL", action: #selector(copyBaseURL), keyEquivalent: "c"))
        menu.addItem(makeMenuItem("Copy Claude Code Config", action: #selector(copyClaudeCodeConfig)))
        menu.addItem(makeMenuItem(model.settings.hasOAuthSession ? "Refresh OpenAI Token" : "Login OpenAI", action: model.settings.hasOAuthSession ? #selector(refreshOpenAIToken) : #selector(loginOpenAI)))
        menu.addItem(makeMenuItem("Settings", action: #selector(openSettings), keyEquivalent: ","))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeRuntimeInfoMenuItem(status: status, latestLog: model.logs.last))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeMenuItem("Quit", action: #selector(quit), keyEquivalent: "q"))
        self.statusItem?.menu = menu
    }

    private func makeMenuItem(_ title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func makeRateLimitsMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let view = NSHostingView(
            rootView: RateLimitsMenuView(
                rows: model.rateLimitMenuRows(),
                footer: model.rateLimitUpdatedDisplay()
            )
        )
        view.frame = NSRect(x: 0, y: 0, width: 280, height: 92)
        item.view = view
        return item
    }

    private func makeModelsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Live Models", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        if model.isRefreshingModels {
            let loading = NSMenuItem(title: "Refreshing...", action: nil, keyEquivalent: "")
            loading.isEnabled = false
            submenu.addItem(loading)
        } else if model.availableModels.isEmpty {
            let empty = NSMenuItem(title: model.modelsError ?? "No models loaded", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for modelDescriptor in model.availableModels {
                let modelItem = NSMenuItem(title: modelDescriptor.id, action: nil, keyEquivalent: "")
                modelItem.toolTip = modelDescriptor.displayName
                modelItem.isEnabled = false
                submenu.addItem(modelItem)
            }
        }

        submenu.addItem(NSMenuItem.separator())
        let refresh = NSMenuItem(title: "Refresh Models", action: #selector(refreshModels), keyEquivalent: "")
        refresh.target = self
        submenu.addItem(refresh)
        item.submenu = submenu
        return item
    }

    private func makeRuntimeInfoMenuItem(status: ProxyRuntimeStatus, latestLog: ProxyLogEntry?) -> NSMenuItem {
        let item = NSMenuItem()
        let view = NSHostingView(
            rootView: RuntimeInfoMenuView(
                statusText: status.isRunning ? "Running \(status.baseURL)" : "Stopped",
                logText: latestLog.map { "\($0.level.rawValue): \($0.message)" }
            )
        )
        view.frame = NSRect(x: 0, y: 0, width: 280, height: latestLog == nil ? 40 : 62)
        item.view = view
        return item
    }

    @objc private func startProxy() {
        model.start()
    }

    @objc private func stopProxy() {
        model.stop()
    }

    @objc private func restartProxy() {
        model.restart()
    }

    @objc private func copyBaseURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.settings.openAIBaseURL, forType: .string)
    }

    @objc private func copyClaudeCodeConfig() {
        model.copyClaudeCodeConfig()
    }

    @objc private func loginOpenAI() {
        model.loginOpenAI()
    }

    @objc private func refreshOpenAIToken() {
        model.refreshOAuthIfNeeded(force: true)
    }

    @objc private func refreshRateLimits() {
        model.refreshRateLimits()
    }

    @objc private func refreshModels() {
        model.refreshModels()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(model: model)
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "CodexAPI"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 580, height: 640))
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        model.stop()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: ProxySettings
    @Published var status: ProxyRuntimeStatus
    @Published var logs: [ProxyLogEntry] = []
    @Published var rateLimits: CodexRateLimits?
    @Published var rateLimitsUpdatedAt: Date?
    @Published var rateLimitsError: String?
    @Published var isRefreshingRateLimits = false
    @Published var availableModels: [CodexModelDescriptor] = []
    @Published var modelsUpdatedAt: Date?
    @Published var modelsError: String?
    @Published var isRefreshingModels = false

    var onChange: (() -> Void)?

    private let store: SettingsStore
    private let server: CodexProxyServer
    private let logger: ProxyLogger
    private let oauthService: CodexOAuthService
    private let rateLimitService: CodexRateLimitService
    private let modelsService: CodexModelsService
    private let shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
    private let resetDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    init(store: SettingsStore, server: CodexProxyServer, logger: ProxyLogger, oauthService: CodexOAuthService, rateLimitService: CodexRateLimitService, modelsService: CodexModelsService) {
        self.store = store
        self.server = server
        self.logger = logger
        self.oauthService = oauthService
        self.rateLimitService = rateLimitService
        self.modelsService = modelsService
        self.settings = store.load()
        self.status = server.currentStatus()
        self.logs = logger.snapshot()

        self.server.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.status = status
                self?.onChange?()
            }
        }
        self.logger.onChange = { [weak self] entries in
            Task { @MainActor in
                self?.logs = entries
                self?.onChange?()
            }
        }
        self.server.onOAuthLogin = { [weak self] tokens in
            Task { @MainActor in
                self?.applyOAuthTokens(tokens)
            }
        }
    }

    func start() {
        do {
            try server.start(settings: settings)
        } catch {
            logger.append(.error, "start failed: \(error)")
        }
    }

    func stop() {
        server.stop()
    }

    func restart() {
        stop()
        start()
    }

    func saveAndRestart() {
        store.save(settings)
        restart()
    }

    func saveAndRefreshModels() {
        store.save(settings)
        server.update(settings: settings)
        onChange?()
        refreshModels()
    }

    func loginOpenAI() {
        if !status.isRunning {
            start()
        }
        if settings.listenPort != 1455 {
            logger.append(.warning, "OpenAI OAuth redirect uses local port \(settings.listenPort); 1455 is the known CLIProxyAPI default.")
        }
        do {
            let redirectURI = oauthService.redirectURI(for: settings)
            let url = try oauthService.beginLogin(redirectURI: redirectURI)
            logger.append(.info, "opening OpenAI OAuth login")
            NSWorkspace.shared.open(url)
        } catch {
            logger.append(.error, "login failed: \(error)")
        }
    }

    func refreshOAuthIfNeeded(force: Bool = false) {
        Task {
            await refreshOAuth(force: force)
        }
    }

    func refreshRateLimits() {
        Task {
            await loadRateLimits()
        }
    }

    func refreshModels() {
        Task {
            await loadModels()
        }
    }

    func logoutOpenAI() {
        settings.clearOAuthTokens()
        rateLimits = nil
        rateLimitsUpdatedAt = nil
        rateLimitsError = nil
        store.save(settings)
        server.update(settings: settings)
        onChange?()
        logger.append(.info, "OpenAI OAuth session cleared")
    }

    func copyClaudeCodeConfig() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(claudeCodeConfigSnippet(), forType: .string)
        logger.append(.info, "Claude Code config copied")
    }

    private func applyOAuthTokens(_ tokens: CodexOAuthTokenBundle) {
        settings.applyOAuthTokens(tokens)
        store.save(settings)
        server.update(settings: settings)
        let label = tokens.email.isEmpty ? tokens.accountID : tokens.email
        logger.append(.info, "OpenAI OAuth token saved\(label.isEmpty ? "" : " for \(label)")")
        refreshRateLimits()
        refreshModels()
    }

    private func refreshOAuth(force: Bool) async {
        guard !settings.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if force {
                logger.append(.warning, "no OpenAI refresh token is available")
            }
            return
        }
        if !force, let expiresAt = settings.tokenExpiresAt, expiresAt > Date().addingTimeInterval(5 * 60) {
            return
        }

        do {
            let tokens = try await oauthService.refreshTokens(refreshToken: settings.refreshToken)
            applyOAuthTokens(tokens)
            logger.append(.info, "OpenAI OAuth token refreshed")
        } catch {
            logger.append(.error, "refresh failed: \(error)")
        }
    }

    private func loadRateLimits() async {
        if isRefreshingRateLimits {
            return
        }
        isRefreshingRateLimits = true
        onChange?()
        defer {
            isRefreshingRateLimits = false
            onChange?()
        }

        await refreshOAuth(force: false)

        do {
            let fetched = try await rateLimitService.fetch(settings: settings)
            rateLimits = fetched
            rateLimitsUpdatedAt = Date()
            rateLimitsError = nil
            logger.append(.info, "rate limits refreshed")
        } catch ProxyError.missingUpstreamToken {
            rateLimits = nil
            rateLimitsUpdatedAt = nil
            rateLimitsError = "Login required"
        } catch {
            rateLimitsError = "\(error)"
            logger.append(.warning, "rate limits unavailable: \(error)")
        }
    }

    private func loadModels() async {
        guard !isRefreshingModels else {
            return
        }
        isRefreshingModels = true
        onChange?()
        defer {
            isRefreshingModels = false
            onChange?()
        }

        await refreshOAuth(force: false)

        do {
            availableModels = try await modelsService.fetch(settings: settings)
            modelsUpdatedAt = Date()
            modelsError = nil
            logger.append(.info, "fetched \(availableModels.count) live Codex models")
        } catch ProxyError.missingUpstreamToken {
            availableModels = []
            modelsUpdatedAt = nil
            modelsError = "Login required"
        } catch {
            modelsError = "\(error)"
            logger.append(.warning, "model refresh failed: \(error)")
        }
    }

    func rateLimitUpdatedDisplay() -> String {
        guard let rateLimitsUpdatedAt else {
            return rateLimitsError ?? "Not loaded"
        }
        return "Updated \(shortTimeFormatter.string(from: rateLimitsUpdatedAt))"
    }

    func modelsUpdatedDisplay() -> String {
        guard let modelsUpdatedAt else {
            return modelsError ?? "Not loaded"
        }
        return "\(availableModels.count) models fetched \(shortTimeFormatter.string(from: modelsUpdatedAt))"
    }

    func rateLimitMenuRows() -> [RateLimitMenuRowState] {
        guard let snapshot = rateLimits?.codexSnapshot else {
            return [rateLimitMenuRow(title: "Limits", window: nil)]
        }
        let windows = [snapshot.primary, snapshot.secondary].compactMap { $0 }
        guard !windows.isEmpty else {
            return [rateLimitMenuRow(title: "Limits", window: nil)]
        }
        return windows.map { rateLimitMenuRow(title: $0.displayName, window: $0) }
    }

    private func rateLimitMenuRow(title: String, window: CodexRateLimitWindow?) -> RateLimitMenuRowState {
        guard let window else {
            return RateLimitMenuRowState(
                title: title,
                remainingPercent: nil,
                detail: rateLimitsError ?? "Not loaded",
                resetText: nil
            )
        }

        return RateLimitMenuRowState(
            title: title,
            remainingPercent: window.remainingPercent,
            detail: String(format: "%.0f%% left", window.remainingPercent),
            resetText: window.resetsAt.map {
                let formatter = window.resetDisplayNeedsDate ? resetDateTimeFormatter : shortTimeFormatter
                return "resets \(formatter.string(from: $0))"
            }
        )
    }

    private func claudeCodeConfigSnippet() -> String {
        let localToken = settings.proxyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "codex-api-local"
            : settings.proxyKey.trimmingCharacters(in: .whitespacesAndNewlines)

        return [
            "export ANTHROPIC_BASE_URL=\(shellQuote(settings.baseURL))",
            "export ANTHROPIC_AUTH_TOKEN=\(shellQuote(localToken))",
            "export ANTHROPIC_API_KEY=\(shellQuote(localToken))",
            "export ANTHROPIC_DEFAULT_OPUS_MODEL=\(shellQuote("gpt-5.6-sol"))",
            "export ANTHROPIC_DEFAULT_SONNET_MODEL=\(shellQuote("gpt-5.6-terra"))",
            "export ANTHROPIC_DEFAULT_HAIKU_MODEL=\(shellQuote("gpt-5.6-luna"))",
            "claude"
        ].joined(separator: "\n")
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

struct RateLimitMenuRowState: Identifiable, Equatable {
    var title: String
    var remainingPercent: Double?
    var detail: String
    var resetText: String?

    var id: String {
        title
    }
}

struct RateLimitsMenuView: View {
    var rows: [RateLimitMenuRowState]
    var footer: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                RateLimitMenuRowView(row: row)
            }

            Text(footer)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 280, height: 92, alignment: .leading)
    }
}

private struct RateLimitMenuRowView: View {
    var row: RateLimitMenuRowState

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(row.title)
                .font(.caption)
                .frame(width: 48, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.detail)
                        .font(.caption)
                    if let resetText = row.resetText {
                        Text(resetText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)

                ProgressView(value: row.remainingPercent ?? 0, total: 100)
                    .progressViewStyle(.linear)
                    .tint(progressTint)
                    .opacity(row.remainingPercent == nil ? 0.35 : 1)
            }
        }
    }

    private var progressTint: Color {
        guard let remainingPercent = row.remainingPercent else {
            return .gray
        }
        if remainingPercent <= 10 {
            return .red
        }
        if remainingPercent <= 30 {
            return .orange
        }
        return .accentColor
    }
}

struct RuntimeInfoMenuView: View {
    var statusText: String
    var logText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let logText {
                Text(logText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 280, alignment: .leading)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var portText: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(model.status.isRunning ? "Running" : "Stopped")
                        .font(.headline)
                    Spacer()
                    Button("Copy URL") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.settings.openAIBaseURL, forType: .string)
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Listen Host")
                        TextField("127.0.0.1", text: $model.settings.listenHost)
                    }
                    GridRow {
                        Text("Listen Port")
                        TextField("1455", text: $portText)
                            .onChange(of: portText) { value in
                                if let port = UInt16(value) {
                                    model.settings.listenPort = port
                                }
                            }
                    }
                    GridRow {
                        Text("Upstream")
                        TextField("https://chatgpt.com/backend-api/codex", text: $model.settings.upstreamBaseURL)
                    }
                    GridRow {
                        Text("Codex Client Version")
                        TextField(ProxySettings.defaultCodexClientVersion, text: $model.settings.codexClientVersion)
                    }
                    GridRow {
                        Text("Token")
                        SecureField("Bearer token", text: $model.settings.authToken)
                    }
                    GridRow {
                        Text("OpenAI Account")
                        Text(model.settings.accountEmail.isEmpty ? (model.settings.accountID.isEmpty ? "Not logged in" : model.settings.accountID) : model.settings.accountEmail)
                            .foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text("Account ID")
                        TextField("optional", text: $model.settings.accountID)
                    }
                    GridRow {
                        Text("Proxy Key")
                        SecureField("optional", text: $model.settings.proxyKey)
                    }
                }

                GroupBox("Live Models") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(model.modelsUpdatedDisplay())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(model.isRefreshingModels ? "Refreshing..." : "Save & Refresh Models") {
                                model.saveAndRefreshModels()
                            }
                            .disabled(model.isRefreshingModels)
                        }

                        if !model.availableModels.isEmpty {
                            Text(model.availableModels.map(\.id).joined(separator: ", "))
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Limits") {
                    VStack(alignment: .leading, spacing: 10) {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                            ForEach(model.rateLimitMenuRows()) { row in
                                GridRow {
                                    Text(row.title)
                                    HStack(spacing: 6) {
                                        Text(row.detail)
                                        if let resetText = row.resetText {
                                            Text(resetText)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }

                        HStack {
                            Text(model.rateLimitUpdatedDisplay())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(model.isRefreshingRateLimits ? "Refreshing..." : "Refresh Limits") {
                                model.refreshRateLimits()
                            }
                            .disabled(model.isRefreshingRateLimits)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Toggle("Inject image_generation tool", isOn: $model.settings.injectImageGenerationTool)

                Divider()

                HStack {
                    Button(model.status.isRunning ? "Stop" : "Start") {
                        if model.status.isRunning {
                            model.stop()
                        } else {
                            model.start()
                        }
                    }
                    Button("Save & Restart") {
                        model.saveAndRestart()
                    }
                    Button(model.settings.hasOAuthSession ? "Refresh Login" : "Login OpenAI") {
                        if model.settings.hasOAuthSession {
                            model.refreshOAuthIfNeeded(force: true)
                        } else {
                            model.loginOpenAI()
                        }
                    }
                    if model.settings.hasOAuthSession {
                        Button("Logout") {
                            model.logoutOpenAI()
                        }
                    }
                    Spacer()
                }

                List(model.logs.suffix(8)) { entry in
                    Text("[\(entry.level.rawValue)] \(entry.message)")
                        .lineLimit(2)
                }
                .frame(height: 140)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .onAppear {
            portText = "\(model.settings.listenPort)"
        }
    }
}
