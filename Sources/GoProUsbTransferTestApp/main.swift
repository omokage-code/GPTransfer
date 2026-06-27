import AppKit
import AVKit
import Darwin
import Foundation
import IOKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class TransferGuard {
    static let shared = TransferGuard()
    var isTransferring = false

    private init() {}
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard TransferGuard.shared.isTransferring else {
            return .terminateNow
        }

        NSAlert.transferInProgress().runModal()
        return .terminateCancel
    }
}

@main
struct GoProUsbTransferTestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 430, idealWidth: 700, minHeight: 340, idealHeight: 500)
                .background(WindowCloseGuard())
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 700, height: 500)
        .commands {
            CameraTransferCommands()
        }
    }
}

struct CameraTransferCommands: Commands {
    @FocusedValue(\.cameraTransferModel) private var model

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Select All Camera Files") {
                model?.selectAllItems()
            }
            .keyboardShortcut("a")
            .disabled(model == nil)

            Button("Copy File Name") {
                model?.copySelectedFileNames()
            }
            .keyboardShortcut("c")
            .disabled(model?.hasSelection != true)
        }
    }
}

struct CameraTransferModelKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var cameraTransferModel: AppModel? {
        get { self[CameraTransferModelKey.self] }
        set { self[CameraTransferModelKey.self] = newValue }
    }
}

struct WindowCloseGuard: NSViewRepresentable {
    private enum DefaultsKey {
        static let windowWidth = "gpTransfer.window.width"
        static let windowHeight = "gpTransfer.window.height"
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.configure(window: nsView.window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private weak var configuredWindow: NSWindow?
        private var isApplyingSavedSize = false

        func configure(window: NSWindow?) {
            guard let window else { return }
            window.delegate = self
            guard configuredWindow !== window else { return }
            configuredWindow = window
            applySavedSize(to: window)
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard TransferGuard.shared.isTransferring else {
                return true
            }

            NSAlert.transferInProgress().runModal()
            return false
        }

        func windowDidResize(_ notification: Notification) {
            guard !isApplyingSavedSize,
                  let window = notification.object as? NSWindow else {
                return
            }
            saveSize(window.contentLayoutRect.size)
        }

        private func applySavedSize(to window: NSWindow) {
            let defaults = UserDefaults.standard
            let width = defaults.double(forKey: DefaultsKey.windowWidth)
            let height = defaults.double(forKey: DefaultsKey.windowHeight)
            guard width >= 430, height >= 340 else { return }

            isApplyingSavedSize = true
            window.setContentSize(NSSize(width: width, height: height))
            isApplyingSavedSize = false
        }

        private func saveSize(_ size: NSSize) {
            guard size.width >= 430, size.height >= 340 else { return }
            let defaults = UserDefaults.standard
            defaults.set(size.width, forKey: DefaultsKey.windowWidth)
            defaults.set(size.height, forKey: DefaultsKey.windowHeight)
        }
    }
}

struct KeyboardShortcutHandler: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.installMonitor()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.model = model
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor
    final class Coordinator {
        var model: AppModel
        private var monitor: Any?

        init(model: AppModel) {
            self.model = model
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            if NSApp.keyWindow?.firstResponder is NSTextView {
                return event
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command),
                  let key = event.charactersIgnoringModifiers?.lowercased() else {
                return event
            }

            switch key {
            case "a":
                model.selectAllItems()
                return nil
            case "c":
                model.copySelectedFileNames()
                return nil
            default:
                return event
            }
        }
    }
}

extension NSAlert {
    static func transferInProgress() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Transfer in progress"
        alert.informativeText = "Wait for Done or press Cancel before closing the app."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        return alert
    }

    static func cameraDisconnectedDuringTransfer(_ message: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Camera disconnected"
        alert.informativeText = "The transfer was stopped. The unfinished file was not marked as done.\n\n\(message)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        return alert
    }

    static func fileConflict(fileName: String) -> NSAlert {
        let alert = NSAlert()
        if Locale.current.language.languageCode?.identifier == "ja" {
            alert.messageText = "\"\(fileName)\" という名前の項目がすでにこの場所にあります。"
            alert.informativeText = "現在転送中の項目で置き換えますか？"
            alert.addButton(withTitle: "両方とも残す")
            alert.addButton(withTitle: "中止")
            alert.addButton(withTitle: "置き換える")
        } else {
            alert.messageText = "An item named \"\(fileName)\" already exists in this location."
            alert.informativeText = "Do you want to replace it with the item you are transferring?"
            alert.addButton(withTitle: "Keep Both")
            alert.addButton(withTitle: "Stop")
            alert.addButton(withTitle: "Replace")
        }
        alert.alertStyle = .warning
        return alert
    }
}

enum FileConflictChoice {
    case keepBoth
    case cancel
    case replace
}

struct ResolvedDestination {
    let url: URL
    let replacesExistingFile: Bool
}

struct ExpandedMediaList {
    let items: [MediaItem]
    let deferredCandidates: [AppModel.CompanionMediaCandidate]
}

@MainActor
func askFileConflictChoice(fileName: String) -> FileConflictChoice {
    let response = NSAlert.fileConflict(fileName: fileName).runModal()
    switch response {
    case .alertFirstButtonReturn:
        return .keepBoth
    case .alertSecondButtonReturn:
        return .cancel
    default:
        return .replace
    }
}

@MainActor
func resolveDestinationForWrite(original: URL) throws -> ResolvedDestination {
    let fileManager = FileManager.default
    let originalPath = original.path(percentEncoded: false)
    let originalPartial = externalPartialURL(for: original)
    let originalPartialPath = originalPartial.path(percentEncoded: false)

    guard fileManager.fileExists(atPath: originalPath) else {
        if fileManager.fileExists(atPath: originalPartialPath) {
            throw AppError.message("A .partial file already exists. To protect data, transfer will not start: \(originalPartialPath)")
        }
        return ResolvedDestination(url: original, replacesExistingFile: false)
    }

    switch askFileConflictChoice(fileName: original.lastPathComponent) {
    case .keepBoth:
        return ResolvedDestination(url: copyDestinationURL(for: original), replacesExistingFile: false)
    case .cancel:
        throw CancellationError()
    case .replace:
        if fileManager.fileExists(atPath: originalPartialPath) {
            throw AppError.message("A .partial file already exists. To protect data, transfer will not start: \(originalPartialPath)")
        }
        return ResolvedDestination(url: original, replacesExistingFile: true)
    }
}

func copyDestinationURL(for original: URL) -> URL {
    let fileManager = FileManager.default
    let folder = original.deletingLastPathComponent()
    let fileName = original.lastPathComponent
    let base = (fileName as NSString).deletingPathExtension
    let ext = (fileName as NSString).pathExtension
    let isJapanese = Locale.current.language.languageCode?.identifier == "ja"

    var counter = 1
    while true {
        let suffix: String
        if isJapanese {
            suffix = counter == 1 ? " のコピー" : " のコピー \(counter)"
        } else {
            suffix = counter == 1 ? " copy" : " copy \(counter)"
        }
        let candidateName = ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)"
        let candidate = folder.appendingPathComponent(candidateName)
        if !fileManager.fileExists(atPath: candidate.path(percentEncoded: false)),
           !fileManager.fileExists(atPath: externalPartialURL(for: candidate).path(percentEncoded: false)) {
            return candidate
        }
        counter += 1
    }
}

actor TransferGate {
    static let shared = TransferGate()

    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}

func withExclusiveTransfer<T>(_ operation: () async throws -> T) async throws -> T {
    await TransferGate.shared.acquire()
    do {
        try Task.checkCancellation()
        let result = try await operation()
        await TransferGate.shared.release()
        return result
    } catch {
        await TransferGate.shared.release()
        throw error
    }
}

enum CameraAutoLaunchAgent {
    static let label = "local.gp-transfer.gp-transfer-4gb.autostart"
    private static let legacyLabels = ["local.camera-transfer.gp-transfer-4gb.autostart"]
    private static let helperExecutableName = "GPTransfer AutoLauncher"

    private static var launchAgentsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    private static var plistURL: URL {
        plistURL(for: label)
    }

    private static func plistURL(for label: String) -> URL {
        launchAgentsFolder.appendingPathComponent("\(label).plist")
    }

    static func isInstalled() -> Bool {
        let labels = [label] + legacyLabels
        return labels.contains { label in
            FileManager.default.fileExists(atPath: plistURL(for: label).path(percentEncoded: false))
        }
    }

    static func migrateLegacyInstallIfNeeded(appURL: URL) throws {
        let currentInstalled = FileManager.default.fileExists(atPath: plistURL.path(percentEncoded: false))
        let legacyInstalled = legacyLabels.contains { label in
            FileManager.default.fileExists(atPath: plistURL(for: label).path(percentEncoded: false))
        }
        let currentNeedsRewrite = currentInstalled && !installedAgentMatchesCurrentBundle(appURL: appURL)

        guard legacyInstalled || currentNeedsRewrite else { return }

        if currentInstalled && !currentNeedsRewrite {
            try removeInstalledAgents(labels: legacyLabels)
            try? FileManager.default.removeItem(at: legacyStateFileURL)
            try? FileManager.default.removeItem(at: olderLegacyStateFileURL)
        } else {
            try install(appURL: appURL)
        }
    }

    static func install(appURL: URL) throws {
        try FileManager.default.createDirectory(at: launchAgentsFolder, withIntermediateDirectories: true)
        try? removeInstalledAgents(labels: legacyLabels)
        try? runLaunchctl(["bootout", launchdDomain, plistURL.path(percentEncoded: false)])
        let helperURL = appURL.appendingPathComponent("Contents/MacOS/\(helperExecutableName)")
        guard FileManager.default.fileExists(atPath: helperURL.path(percentEncoded: false)) else {
            throw AppError.message("Auto launch helper was not found in the app bundle.")
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [
                helperURL.path(percentEncoded: false),
                appURL.path(percentEncoded: false)
            ],
            "RunAtLoad": true,
            "StartInterval": 5
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        try runLaunchctl(["bootstrap", launchdDomain, plistURL.path(percentEncoded: false)])
    }

    static func uninstall() throws {
        try removeInstalledAgents(labels: [label] + legacyLabels)
        try? FileManager.default.removeItem(at: stateFileURL)
        try? FileManager.default.removeItem(at: legacyStateFileURL)
        try? FileManager.default.removeItem(at: olderLegacyStateFileURL)
    }

    private static func removeInstalledAgents(labels: [String]) throws {
        for label in labels {
            let url = plistURL(for: label)
            try? runLaunchctl(["bootout", launchdDomain, url.path(percentEncoded: false)])
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func installedAgentMatchesCurrentBundle(appURL: URL) -> Bool {
        let helperURL = appURL.appendingPathComponent("Contents/MacOS/\(helperExecutableName)")
        guard let plist = NSDictionary(contentsOf: plistURL) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String],
              arguments.count >= 2 else {
            return false
        }
        return arguments[0] == helperURL.path(percentEncoded: false)
            && arguments[1] == appURL.path(percentEncoded: false)
    }

    private static var stateFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GPTransfer", isDirectory: true)
            .appendingPathComponent("auto-launch-camera-present")
    }

    private static var legacyStateFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GP Transfer", isDirectory: true)
            .appendingPathComponent("auto-launch-camera-present")
    }

    private static var olderLegacyStateFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Camera Transfer", isDirectory: true)
            .appendingPathComponent("auto-launch-camera-present")
    }

    private static var launchdDomain: String {
        "gui/\(getuid())"
    }

    private static func runLaunchctl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppError.message("launchctl failed: \(message ?? arguments.joined(separator: " "))")
        }
    }
}

struct ContentView: View {
    private static let supportDevelopmentURL = URL(string: "https://buymeacoffee.com/omokage")!

    @StateObject private var model = AppModel()
    @StateObject private var playbackStore = VideoPlaybackStore()
    @State private var showDiagnostics = false
    @State private var showAdvancedSettings = false
    @State private var isSupportDevelopmentLinkHovered = false
    @State private var transferLogSearch = ""
    @State private var viewMode: MediaViewMode = .list
    @State private var thumbnailSize = 132.0
    @State private var listColumnOrder: [MediaSortKey] = [.created, .kind, .size]
    @State private var listColumnWidths: [MediaSortKey: CGFloat] = [
        .name: 260,
        .created: 180,
        .kind: 110,
        .size: 170
    ]
    @State private var draggedListColumn: MediaSortKey?
    @State private var listColumnDragOffset: CGFloat = 0

    init() {
        _listColumnOrder = State(initialValue: Self.loadListColumnOrder())
        _listColumnWidths = State(initialValue: Self.loadListColumnWidths())
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                mainPanels
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .layoutPriority(1)

                compactTransferPanel
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .layoutPriority(4)

                footer
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .layoutPriority(5)
            }
        }
        .background(appBackground)
        .task {
            await model.monitorCameraConnection()
        }
        .focusedValue(\.cameraTransferModel, model)
        .background(KeyboardShortcutHandler(model: model))
    }

    private var mainPanels: some View {
        VStack(alignment: .leading, spacing: 8) {
            topPanel
                .layoutPriority(3)
            mediaPanel
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var compactTransferPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            transferActionPanel
            if model.isTransferring {
                transferProgressPanel
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelBackground)
    }

    private var topPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            connectionPanel
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelBackground)
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                headerTitle
                Spacer()
                readOnlyNotice
            }

            VStack(alignment: .leading, spacing: 6) {
                headerTitle
                readOnlyNotice
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerTitle: some View {
        HStack(alignment: .center, spacing: 12) {
            GPTransferHeaderLogo()
                .frame(width: 88, height: 66)

            VStack(alignment: .center, spacing: 1) {
                Text("GPTransfer")
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.1)
                Text("4GB+ safely from GoPro")
                    .font(.system(size: 11.9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
        }
    }

    private var readOnlyNotice: some View {
        Text("Read only. Camera files are not changed.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 14) {
                    connectionActions
                    saveFolderBar
                        .frame(minWidth: 230, maxWidth: .infinity)
                    advancedButton
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        connectionActions
                        Spacer(minLength: 8)
                        advancedButton
                    }
                    saveFolderBar
                        .frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        connectionActions
                        Spacer(minLength: 8)
                        advancedButton
                    }
                    saveFolderBar
                        .frame(maxWidth: .infinity)
                }
            }

            if model.saveFolder != nil {
                partialFilesPanel
            }
        }
    }

    private var connectionActions: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.autoConnect() }
            } label: {
                Label("Connect", systemImage: "bolt.horizontal")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy)

            Button {
                model.prepareSafeDisconnect()
            } label: {
                Label("Eject", systemImage: "eject")
            }
            .disabled(model.isTransferring || model.autoConnectPaused || !model.isConnected)

            connectionBadge
        }
        .controlSize(.regular)
    }

    private var connectionBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.isConnected ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(model.connectionLabel)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(model.isConnected ? .green : .secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var saveFolderBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Save To")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(model.saveFolder?.path(percentEncoded: false) ?? "No save folder")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(model.saveFolder == nil ? .secondary : .primary)
                Spacer(minLength: 8)
                Button {
                    model.chooseSaveFolder()
                } label: {
                    Label("Choose", systemImage: "ellipsis")
                }
                .disabled(model.isBusy)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(controlBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(model.saveFolder == nil ? Color.orange : Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }

    private var advancedButton: some View {
        Button {
            showAdvancedSettings.toggle()
        } label: {
            Label("Advanced", systemImage: "gearshape")
        }
        .controlSize(.regular)
        .popover(isPresented: $showAdvancedSettings, arrowEdge: .bottom) {
            autoLaunchControl
                .padding(12)
        }
    }

    private var autoLaunchControl: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Auto Launch")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Toggle(
                "Open when camera is connected",
                isOn: Binding(
                    get: { model.autoLaunchOnCameraConnection },
                    set: { model.setAutoLaunchOnCameraConnection($0) }
                )
            )
            .toggleStyle(.checkbox)
            Text(model.autoLaunchStatus)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(model.autoLaunchStatusIsError ? .red : .secondary)
                .textSelection(.enabled)
        }
        .frame(width: 260, alignment: .leading)
    }

    private var partialFilesPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Unfinished")
                    .frame(width: 76, alignment: .leading)
                Text("\(model.partialFiles.count)")
                    .foregroundStyle(model.partialFiles.isEmpty ? Color.secondary : Color.orange)
                Spacer()
                Button("Refresh") {
                    model.refreshPartialFiles()
                }
                .disabled(model.isBusy)
            }

            if !model.partialFiles.isEmpty {
                VStack(spacing: 4) {
                    ForEach(model.partialFiles) { file in
                        HStack(spacing: 8) {
                            Image(systemName: file.isDirectory ? "folder" : "doc")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(file.displayName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(file.sizeDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Move to Trash") {
                                model.confirmAndTrashPartialFile(file)
                            }
                            .disabled(model.isBusy || model.isTransferring)
                        }
                        .font(.caption)
                    }
                }
                .padding(8)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var mediaPanel: some View {
        GeometryReader { geometry in
            let reservedHeight: CGFloat = 76
            let listHeight = max(geometry.size.height - reservedHeight, 44)

            VStack(alignment: .leading, spacing: 6) {
                fileToolbar

                Group {
                    switch viewMode {
                    case .list:
                        mediaList
                    case .thumbnails:
                        thumbnailGrid
                    }
                }
                .frame(height: listHeight)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

                if !model.transferQueue.isEmpty {
                    transferQueuePanel
                }

                if !model.transferLog.isEmpty {
                    diagnosticsPanel
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(panelBackground)
        }
        .frame(minHeight: 88, maxHeight: .infinity)
        .layoutPriority(1)
    }

    private var fileToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 14) {
                fileToolbarTitle
                    .frame(minWidth: 150, idealWidth: 180, maxWidth: 210, alignment: .leading)

                Spacer(minLength: 8)

                toolbarControls
            }

            VStack(alignment: .leading, spacing: 6) {
                fileToolbarTitle
                ScrollView(.horizontal, showsIndicators: false) {
                    toolbarControls
                }
            }
        }
        .padding(.bottom, 2)
    }

    private var toolbarControls: some View {
        HStack(alignment: .center, spacing: 14) {
            viewPicker
                .frame(width: 180)
            typePicker
                .frame(width: 350)
            sortPicker
                .frame(width: 160)
        }
    }

    private var fileToolbarTitle: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Files")
                .font(.headline)
            Text(model.selectionSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var viewPicker: some View {
        Picker("View", selection: $viewMode) {
            ForEach(MediaViewMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var typePicker: some View {
        HStack(spacing: 8) {
            Text("Type")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Picker("Type", selection: $model.mediaKindFilter) {
                ForEach(MediaKindFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private var sortPicker: some View {
        HStack(spacing: 8) {
            Text("Sort")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Picker("Sort", selection: $model.sortKey) {
                ForEach(MediaSortKey.allCases) { key in
                    Text(key.label).tag(key)
                }
            }
            .labelsHidden()
        }
    }

    private var transferActionPanel: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 12) {
                selectedTransferPanel
                    .frame(width: 125, alignment: .leading)

                transferButtonGroup
                    .frame(minWidth: 280, maxWidth: .infinity)

                Spacer(minLength: 0)

                queueSummaryPanel
                    .frame(width: 160, alignment: .leading)

                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    selectedTransferPanel
                        .frame(width: 125, alignment: .leading)
                    Spacer(minLength: 8)
                    queueSummaryPanel
                        .frame(width: 160, alignment: .leading)
                }

                transferButtonGroup
            }

            VStack(alignment: .leading, spacing: 8) {
                selectedTransferPanel
                queueSummaryPanel
                transferButtonGroup
                HStack(spacing: 10) {
                    cancelButton
                    clearButton
                    if model.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var selectedTransferPanel: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.selectedTransferCountText)
                .font(.headline)
            Text(model.selectedTransferSizeText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var transferButtonGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.transferUnavailableReason ?? "Ready to transfer.")
                .font(.caption)
                .foregroundStyle(model.transferUnavailableReason == nil ? Color.secondary : Color.orange)
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 8) {
                transferButton
                    .frame(minWidth: 120, maxWidth: .infinity)
                cancelButton
                    .frame(width: 96)
                clearButton
                    .frame(width: 78)
            }
        }
    }

    private var transferButton: some View {
        Button {
            model.startDownloadSelectedItem()
        } label: {
            Label("Transfer", systemImage: "square.and.arrow.down")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(model.saveFolder == nil || !model.canStartManualTransfer || (model.isBusy && !model.isTransferring))
    }

    private var cancelButton: some View {
        Button(role: .cancel) {
            model.cancelTransfer()
        } label: {
            Label("Cancel", systemImage: "stop.circle")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .disabled(!model.isTransferring)
    }

    private var clearButton: some View {
        Button {
            model.clearSelection()
        } label: {
            Label("Clear", systemImage: "xmark.circle")
        }
        .disabled(!model.hasSelection)
    }

    private var queueSummaryPanel: some View {
        HStack(spacing: 8) {
            Image(systemName: model.transferQueue.isEmpty ? "checkmark.circle" : "arrow.down.circle")
                .foregroundStyle(model.transferQueue.isEmpty ? .green : .accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text("Queue")
                    .font(.headline)
                Text(model.transferQueue.isEmpty ? "No active transfer" : model.transferQueueSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var transferProgressPanel: some View {
        VStack(alignment: .leading, spacing: 5) {
            ProgressView(value: model.transferProgress)
                .progressViewStyle(.linear)
            HStack {
                Text(model.transferProgressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Do not unplug. Wait for Done or Cancel.")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var filteredTransferLog: [TransferLogEntry] {
        let query = transferLogSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return model.transferLog
        }
        return model.transferLog.filter { entry in
            entry.message.localizedCaseInsensitiveContains(query) ||
                entry.timeText.localizedCaseInsensitiveContains(query)
        }
    }

    private var transferQueuePanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Queue")
                    .font(.headline)
                Spacer()
                Text(model.transferQueueSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.transferQueue) { entry in
                        HStack(spacing: 8) {
                            Text(entry.status.label)
                                .font(.caption)
                                .frame(width: 86, alignment: .leading)
                                .foregroundStyle(queueStatusColor(entry.status))
                            Text(entry.item.fileName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if let message = entry.message {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .font(.caption)
                    }
                }
            }
            .frame(maxHeight: 110)
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var diagnosticsPanel: some View {
        DisclosureGroup("Transfer Log", isExpanded: $showDiagnostics) {
            transferLogPanel
        }
    }

    private var transferLogPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Search log", text: $transferLogSearch)
                    .textFieldStyle(.roundedBorder)
                Text("\(filteredTransferLog.count) / \(model.transferLog.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredTransferLog) { entry in
                        HStack(spacing: 8) {
                            Text(entry.timeText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 72, alignment: .leading)
                            Text(entry.message)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                    }
                }
            }
            .frame(maxHeight: 96)
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func queueStatusColor(_ status: TransferQueueStatus) -> Color {
        switch status {
        case .pending:
            return .secondary
        case .active:
            return .accentColor
        case .done:
            return .green
        case .failed:
            return .red
        case .canceled:
            return .orange
        }
    }

    private var mediaList: some View {
        GeometryReader { geometry in
            let viewportWidth = max(geometry.size.width - 16, 1)
            let viewportHeight = max(geometry.size.height, 44)
            let columnWidths = compactedListColumnWidths(for: viewportWidth)
            let minimumTableWidth = listMinimumTableWidth(using: columnWidths)
            let contentWidth = max(viewportWidth, minimumTableWidth)

            VStack(alignment: .leading, spacing: 4) {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        listHeader(
                            contentWidth: contentWidth,
                            minimumTableWidth: minimumTableWidth,
                            columnWidths: columnWidths
                        )
                            .frame(width: contentWidth, alignment: .leading)

                        ZStack(alignment: .topLeading) {
                            ClearSelectionClickTarget(model: model)
                                .frame(width: contentWidth)
                                .frame(maxHeight: .infinity)
                            LazyVStack(spacing: 0) {
                                ForEach(Array(model.sortedItems.enumerated()), id: \.element.id) { index, item in
                                    mediaRow(
                                        for: item,
                                        rowIndex: index,
                                        contentWidth: contentWidth,
                                        minimumTableWidth: minimumTableWidth,
                                        columnWidths: columnWidths
                                    )
                                }
                            }
                            .frame(width: contentWidth, alignment: .topLeading)
                        }
                        .frame(width: contentWidth, alignment: .topLeading)
                        .frame(minHeight: 34, alignment: .topLeading)
                    }
                    .frame(width: contentWidth, alignment: .topLeading)
                    .frame(minHeight: viewportHeight, alignment: .topLeading)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .frame(minHeight: 44, maxHeight: .infinity)
    }

    private func listHeader(
        contentWidth: CGFloat,
        minimumTableWidth: CGFloat,
        columnWidths: [MediaSortKey: CGFloat]
    ) -> some View {
        HStack(spacing: 0) {
            Text("")
                .frame(width: listSelectionColumnWidth, alignment: .center)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .trailing) {
                    listColumnSeparator
                }
            sortHeader(.name)
                .padding(.horizontal, listCellHorizontalPadding)
                .frame(width: listColumnWidth(for: .name, using: columnWidths), alignment: .leading)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .trailing) {
                    listHeaderResizeHandle(for: .name)
                }
            ForEach(listColumnOrder, id: \.self) { key in
                reorderableListHeader(for: key, width: listColumnWidth(for: key, using: columnWidths))
            }
            if contentWidth > minimumTableWidth {
                Color.clear
                    .frame(width: contentWidth - minimumTableWidth)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(height: 34, alignment: .center)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .bottom) {
            listHeaderSeparator
        }
    }

    private func mediaRow(
        for item: MediaItem,
        rowIndex: Int,
        contentWidth: CGFloat,
        minimumTableWidth: CGFloat,
        columnWidths: [MediaSortKey: CGFloat]
    ) -> some View {
        let isSelected = model.isItemSelected(item)

        return ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                selectionIndicator(isSelected: isSelected)
                    .frame(width: listSelectionColumnWidth, alignment: .center)
                    .frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.fileName)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.directory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, listCellHorizontalPadding)
                .frame(width: listColumnWidth(for: .name, using: columnWidths), alignment: .leading)
                .frame(maxHeight: .infinity)
                ForEach(listColumnOrder, id: \.self) { key in
                    listCell(for: key, item: item, width: listColumnWidth(for: key, using: columnWidths))
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .frame(width: contentWidth, alignment: .leading)

            ExternalDragSource(model: model, item: item, togglesSelectionAtLeadingEdge: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if contentWidth > minimumTableWidth {
                ClearSelectionClickTarget(model: model)
                    .frame(width: contentWidth - minimumTableWidth)
                    .frame(maxHeight: .infinity)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .background(listRowBackground(isSelected: isSelected, rowIndex: rowIndex))
        .overlay(alignment: .bottom) {
            listRowSeparator
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy Name") {
                model.copyFileName(item)
            }
        }
    }

    private func reorderableListHeader(for key: MediaSortKey, width: CGFloat) -> some View {
        listHeaderLabel(key)
            .padding(.horizontal, listCellHorizontalPadding)
            .frame(
                width: width,
                height: 34,
                alignment: listColumnAlignment(for: key)
            )
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(draggedListColumn == key ? Color.accentColor.opacity(0.10) : Color.clear)
            }
            .overlay(alignment: .trailing) {
                if key != listColumnOrder.last {
                    listHeaderResizeHandle(for: key)
                }
            }
            .offset(x: draggedListColumn == key ? listColumnDragOffset : 0)
            .zIndex(draggedListColumn == key ? 2 : 0)
            .onTapGesture {
                model.toggleSort(key)
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in
                        if draggedListColumn != key {
                            draggedListColumn = key
                            listColumnDragOffset = 0
                        }
                    }
                    .onChanged { value in
                        draggedListColumn = key
                        listColumnDragOffset = value.translation.width
                    }
                    .onEnded { value in
                        moveListColumn(key, by: value.translation.width)
                        draggedListColumn = nil
                        listColumnDragOffset = 0
                    }
            )
    }

    @ViewBuilder
    private func listCell(for key: MediaSortKey, item: MediaItem, width: CGFloat) -> some View {
        switch key {
        case .created:
            Text(item.createdDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, listCellHorizontalPadding)
                .frame(width: width, alignment: .leading)
                .frame(maxHeight: .infinity)
        case .kind:
            Text(item.kindDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, listCellHorizontalPadding)
                .frame(width: width, alignment: .leading)
                .frame(maxHeight: .infinity)
        case .size:
            sizeCell(for: item)
                .padding(.horizontal, listCellHorizontalPadding)
                .frame(width: width, alignment: .leading)
                .frame(maxHeight: .infinity)
        case .name:
            EmptyView()
        }
    }

    private func listColumnWidth(for key: MediaSortKey) -> CGFloat {
        listColumnWidths[key] ?? Self.defaultListColumnWidth(for: key)
    }

    private func listColumnWidth(for key: MediaSortKey, using widths: [MediaSortKey: CGFloat]) -> CGFloat {
        widths[key] ?? listColumnWidth(for: key)
    }

    private func compactedListColumnWidths(for viewportWidth: CGFloat) -> [MediaSortKey: CGFloat] {
        var widths = ([MediaSortKey.name] + listColumnOrder).reduce(into: [MediaSortKey: CGFloat]()) { result, key in
            result[key] = listColumnWidth(for: key)
        }
        let minimumWidths = ([MediaSortKey.name] + listColumnOrder).reduce(into: [MediaSortKey: CGFloat]()) { result, key in
            result[key] = Self.listColumnWidthRange(for: key).lowerBound
        }
        let minimumTableWidth = listMinimumTableWidth(using: minimumWidths)
        let targetWidth = max(viewportWidth, minimumTableWidth)
        var overflow = listMinimumTableWidth(using: widths) - targetWidth
        guard overflow > 0 else {
            return widths
        }

        for key in [MediaSortKey.created, .kind, .size, .name] where overflow > 0 {
            let currentWidth = widths[key] ?? Self.defaultListColumnWidth(for: key)
            let minimumWidth = minimumWidths[key] ?? Self.listColumnWidthRange(for: key).lowerBound
            let reducibleWidth = Swift.max(currentWidth - minimumWidth, CGFloat(0))
            let reduction = Swift.min(reducibleWidth, overflow)
            widths[key] = currentWidth - reduction
            overflow -= reduction
        }

        return widths
    }

    private static func defaultListColumnWidth(for key: MediaSortKey) -> CGFloat {
        switch key {
        case .name:
            return 260
        case .created:
            return 180
        case .kind:
            return 110
        case .size:
            return 170
        }
    }

    private static var defaultListColumnOrder: [MediaSortKey] {
        [.created, .kind, .size]
    }

    private static var defaultListColumnWidths: [MediaSortKey: CGFloat] {
        Dictionary(uniqueKeysWithValues: ([.name] + defaultListColumnOrder).map { key in
            (key, defaultListColumnWidth(for: key))
        })
    }

    private enum ListPreferenceKey {
        static let columnOrder = "gpTransfer.list.columnOrder"
        static let columnWidths = "gpTransfer.list.columnWidths"
    }

    private static func loadListColumnOrder() -> [MediaSortKey] {
        let savedValues = UserDefaults.standard.stringArray(forKey: ListPreferenceKey.columnOrder) ?? []
        var order = savedValues.compactMap(MediaSortKey.init(rawValue:))
            .filter { $0 != .name }
        order = order.reduce(into: []) { result, key in
            if !result.contains(key) {
                result.append(key)
            }
        }
        for key in defaultListColumnOrder where !order.contains(key) {
            order.append(key)
        }
        return order.filter { defaultListColumnOrder.contains($0) }
    }

    private static func loadListColumnWidths() -> [MediaSortKey: CGFloat] {
        var widths = defaultListColumnWidths
        let saved = UserDefaults.standard.dictionary(forKey: ListPreferenceKey.columnWidths) as? [String: Double] ?? [:]
        for (rawKey, savedWidth) in saved {
            guard let key = MediaSortKey(rawValue: rawKey) else { continue }
            let range = Self.listColumnWidthRange(for: key)
            widths[key] = min(max(CGFloat(savedWidth), range.lowerBound), range.upperBound)
        }
        return widths
    }

    private static func saveListColumnOrder(_ order: [MediaSortKey]) {
        UserDefaults.standard.set(order.map(\.rawValue), forKey: ListPreferenceKey.columnOrder)
    }

    private static func saveListColumnWidths(_ widths: [MediaSortKey: CGFloat]) {
        let payload = widths.reduce(into: [String: Double]()) { result, entry in
            result[entry.key.rawValue] = Double(entry.value)
        }
        UserDefaults.standard.set(payload, forKey: ListPreferenceKey.columnWidths)
    }

    private func listColumnAlignment(for key: MediaSortKey) -> Alignment {
        .leading
    }

    private var listMinimumTableWidth: CGFloat {
        listSelectionColumnWidth + listColumnWidth(for: .name) + listColumnOrder.reduce(CGFloat(0)) { total, key in
            total + listColumnWidth(for: key)
        }
    }

    private func listMinimumTableWidth(using widths: [MediaSortKey: CGFloat]) -> CGFloat {
        listSelectionColumnWidth
            + listColumnWidth(for: .name, using: widths)
            + listColumnOrder.reduce(CGFloat(0)) { total, key in
                total + listColumnWidth(for: key, using: widths)
            }
    }

    private var listSelectionColumnWidth: CGFloat {
        34
    }

    private var listCellHorizontalPadding: CGFloat {
        10
    }

    private var listColumnSeparator: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.12))
            .frame(width: 1)
    }

    private var listHeaderSeparator: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.7))
            .frame(height: 1)
    }

    private func listHeaderResizeHandle(for key: MediaSortKey) -> some View {
        ColumnResizeHandle(
            width: Binding(
                get: { listColumnWidth(for: key) },
                set: { resizeListColumn(key, to: $0) }
            ),
            range: Self.listColumnWidthRange(for: key)
        )
        .frame(width: 11)
    }

    private func resizeListColumn(_ key: MediaSortKey, to proposedWidth: CGFloat) {
        let range = Self.listColumnWidthRange(for: key)
        listColumnWidths[key] = min(max(proposedWidth, range.lowerBound), range.upperBound)
        Self.saveListColumnWidths(listColumnWidths)
    }

    private static func listColumnWidthRange(for key: MediaSortKey) -> ClosedRange<CGFloat> {
        switch key {
        case .name:
            return 140...520
        case .created:
            return 142...280
        case .kind:
            return 68...220
        case .size:
            return 132...280
        }
    }

    private var listRowSeparator: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.34))
            .frame(height: 1)
    }

    private func listRowBackground(isSelected: Bool, rowIndex: Int) -> Color {
        if isSelected {
            return Color.accentColor.opacity(0.18)
        }
        if rowIndex.isMultiple(of: 2) {
            return Color(nsColor: .textBackgroundColor)
        }
        return Color(red: 0.965, green: 0.982, blue: 1.0)
    }

    private func moveListColumn(_ key: MediaSortKey, by horizontalTranslation: CGFloat) {
        guard key != .name,
              let fromIndex = listColumnOrder.firstIndex(of: key),
              abs(horizontalTranslation) > 18 else {
            return
        }

        let currentCenter = listColumnCenter(for: key, in: listColumnOrder)
        let draggedCenter = currentCenter + horizontalTranslation
        let target = listColumnOrder.min { left, right in
            abs(listColumnCenter(for: left, in: listColumnOrder) - draggedCenter)
                < abs(listColumnCenter(for: right, in: listColumnOrder) - draggedCenter)
        }

        guard let target,
              let toIndex = listColumnOrder.firstIndex(of: target),
              toIndex != fromIndex else {
            return
        }

        withAnimation(.easeInOut(duration: 0.12)) {
            listColumnOrder.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
        }
        Self.saveListColumnOrder(listColumnOrder)
    }

    private func listColumnCenter(for key: MediaSortKey, in order: [MediaSortKey]) -> CGFloat {
        var x: CGFloat = 0
        for column in order {
            let width = listColumnWidth(for: column)
            if column == key {
                return x + width / 2
            }
            x += width
        }
        return 0
    }

    private func sizeCell(for item: MediaItem) -> some View {
        HStack(spacing: 8) {
            Text(item.sizeDescription)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(item.isOver4GiB ? .orange : .primary)
                .frame(width: 88, alignment: .leading)
            if item.isOver4GiB {
                Text("Large")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .foregroundStyle(.orange)
                    .background(Color.orange.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.orange.opacity(0.7), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .frame(width: 54, alignment: .leading)
            } else {
                Color.clear
                    .frame(width: 54)
            }
        }
    }

    private func selectionIndicator(isSelected: Bool) -> some View {
        ZStack {
            if isSelected {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    .opacity(0.7)
            }
        }
        .frame(width: 18, height: 18)
    }

    private func sortHeader(_ key: MediaSortKey) -> some View {
        Button {
            model.toggleSort(key)
        } label: {
            listHeaderLabel(key)
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(model.sortKey == key ? .primary : .secondary)
    }

    private func listHeaderLabel(_ key: MediaSortKey) -> some View {
        HStack(spacing: 4) {
            Text(key.label)
            if model.sortKey == key {
                Image(systemName: model.sortAscending ? "chevron.up" : "chevron.down")
                    .font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .font(.caption)
        .foregroundStyle(model.sortKey == key ? .primary : .secondary)
    }

    private var thumbnailGrid: some View {
        let tileWidth = CGFloat(thumbnailSize)

        return ScrollView {
            ZStack(alignment: .topLeading) {
                ClearSelectionClickTarget(model: model)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: tileWidth + 16, maximum: tileWidth + 16), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(model.sortedItems) { item in
                        ThumbnailTile(
                            item: item,
                            thumbnailURL: model.thumbnailURL(for: item),
                            isSelected: model.isItemSelected(item),
                            thumbnailSize: tileWidth,
                            playbackPlayer: playbackStore.activeItemID == item.id ? playbackStore.player : nil,
                            isPlaybackPaused: playbackStore.activeItemID == item.id && playbackStore.isPaused,
                            isPlaybackStarting: playbackStore.activeItemID == item.id && playbackStore.isStarting,
                            showsPlayButton: item.isPlayableVideo,
                            model: model
                        ) {
                            startPlayback(item)
                        } stopAction: {
                            pausePlayback()
                        } resumeAction: {
                            resumePlayback()
                        }
                        .onTapGesture {
                            model.handleMediaSelection(item)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            .padding(.vertical, 4)
        }
        .frame(minHeight: 44, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Link("GPTransfer / Support development ☕", destination: Self.supportDevelopmentURL)
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
                .foregroundStyle(isSupportDevelopmentLinkHovered ? .orange : .secondary)
                .animation(.easeInOut(duration: 0.16), value: isSupportDevelopmentLinkHovered)
                .onHover { isSupportDevelopmentLinkHovered = $0 }
            Spacer(minLength: 8)
            footerStatusArea
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.7))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var footerStatusArea: some View {
        if viewMode == .thumbnails {
            HStack(spacing: 8) {
                if model.statusIsError {
                    Text(model.status)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Slider(value: $thumbnailSize, in: 116...220, step: 1)
                    .frame(width: 128)
            }
            .frame(maxWidth: 240, alignment: .trailing)
        } else {
            Text(model.status)
                .foregroundStyle(model.statusIsError ? .red : .secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func startPlayback(_ item: MediaItem) {
        guard let url = model.playbackURL(for: item) else {
            model.status = "Preview is available for video files only."
            model.statusIsError = true
            return
        }
        playbackStore.play(itemID: item.id, url: url)
    }

    private func pausePlayback() {
        playbackStore.pause()
    }

    private func resumePlayback() {
        playbackStore.resume()
    }

    private var appBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .windowBackgroundColor))
            .shadow(color: Color.black.opacity(0.04), radius: 12, x: 0, y: 4)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
            )
    }

    private var controlBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }
}

struct GPTransferHeaderLogo: View {
    private static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "GPTransferHeaderLogo", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            GPTransferHeaderMark()
        }
    }
}

struct GPTransferHeaderMark: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0.06, green: 0.09, blue: 0.13))
                .frame(width: 72, height: 48)
                .offset(x: 0, y: 14)

            RoundedRectangle(cornerRadius: 6.5)
                .fill(Color(red: 0.09, green: 0.13, blue: 0.19))
                .frame(width: 28, height: 13)
                .offset(x: 9, y: 6)

            RoundedRectangle(cornerRadius: 3.5)
                .fill(Color(red: 0.92, green: 0.96, blue: 1.0).opacity(0.92))
                .frame(width: 14, height: 7)
                .offset(x: 47, y: 23)

            Circle()
                .fill(Color(red: 0.02, green: 0.04, blue: 0.06))
                .frame(width: 40, height: 40)
                .offset(x: 14, y: 18)

            Circle()
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(red: 0.18, green: 0.85, blue: 1.0),
                            Color(red: 0.08, green: 0.45, blue: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 6
                )
                .frame(width: 32, height: 32)
                .offset(x: 18, y: 22)

            Circle()
                .fill(Color(red: 0.87, green: 0.97, blue: 1.0))
                .frame(width: 16, height: 16)
                .offset(x: 26, y: 30)

            Path { path in
                path.move(to: CGPoint(x: 55, y: 45))
                path.addLine(to: CGPoint(x: 86, y: 45))
                path.addLine(to: CGPoint(x: 75, y: 33))
                path.move(to: CGPoint(x: 86, y: 45))
                path.addLine(to: CGPoint(x: 75, y: 57))
            }
            .stroke(
                LinearGradient(
                    colors: [
                        Color(red: 0.18, green: 0.85, blue: 1.0),
                        Color(red: 0.08, green: 0.45, blue: 1.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: 88, height: 66, alignment: .topLeading)
    }
}

struct ColumnResizeHandle: NSViewRepresentable {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>

    func makeNSView(context: Context) -> ResizeHandleView {
        let view = ResizeHandleView()
        view.width = width
        view.range = range
        view.onWidthChange = { newWidth in
            width = newWidth
        }
        return view
    }

    func updateNSView(_ nsView: ResizeHandleView, context: Context) {
        nsView.width = width
        nsView.range = range
        nsView.onWidthChange = { newWidth in
            width = newWidth
        }
    }

    final class ResizeHandleView: NSView {
        var width: CGFloat = 0
        var range: ClosedRange<CGFloat> = 0...0
        var onWidthChange: ((CGFloat) -> Void)?
        private var dragStartX: CGFloat = 0
        private var dragStartWidth: CGFloat = 0

        override var acceptsFirstResponder: Bool {
            true
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            dragStartX = event.locationInWindow.x
            dragStartWidth = width
        }

        override func mouseDragged(with event: NSEvent) {
            let delta = event.locationInWindow.x - dragStartX
            let proposedWidth = dragStartWidth + delta
            onWidthChange?(min(max(proposedWidth, range.lowerBound), range.upperBound))
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)

            let lineRect = NSRect(
                x: floor(bounds.midX),
                y: bounds.minY,
                width: 1,
                height: bounds.height
            )
            NSColor.separatorColor.withAlphaComponent(0.12).setFill()
            lineRect.fill()
        }
    }
}

struct ListColumnDropDelegate: DropDelegate {
    let target: MediaSortKey
    @Binding var columnOrder: [MediaSortKey]
    @Binding var draggedColumn: MediaSortKey?

    func dropEntered(info: DropInfo) {
        guard let draggedColumn,
              draggedColumn != target,
              let fromIndex = columnOrder.firstIndex(of: draggedColumn),
              let toIndex = columnOrder.firstIndex(of: target) else {
            return
        }

        withAnimation(.easeInOut(duration: 0.12)) {
            columnOrder.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedColumn = nil
        return true
    }
}

struct ExternalDragSource: NSViewRepresentable {
    @ObservedObject var model: AppModel
    let item: MediaItem
    var togglesSelectionAtLeadingEdge = false

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        view.model = model
        view.item = item
        view.togglesSelectionAtLeadingEdge = togglesSelectionAtLeadingEdge
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ nsView: DragSourceView, context: Context) {
        nsView.model = model
        nsView.item = item
        nsView.togglesSelectionAtLeadingEdge = togglesSelectionAtLeadingEdge
        nsView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    final class DragSourceView: NSView, NSDraggingSource {
        weak var model: AppModel?
        var item: MediaItem?
        var togglesSelectionAtLeadingEdge = false
        private var mouseDownEvent: NSEvent?

        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
        }

        override func mouseDragged(with event: NSEvent) {
            guard mouseDownEvent != nil else { return }
            guard let model, let item else { return }
            let draggingItems = model.externalDraggingItems(startingAt: item, draggingFrame: bounds)
            guard !draggingItems.isEmpty else { return }
            beginDraggingSession(with: draggingItems, event: event, source: self)
            mouseDownEvent = nil
        }

        override func mouseUp(with event: NSEvent) {
            guard let model, let item else { return }
            let localPoint = convert(event.locationInWindow, from: nil)
            if togglesSelectionAtLeadingEdge, localPoint.x <= 36 {
                model.toggleSelection(item)
            } else {
                model.handleMediaSelection(item)
            }
            mouseDownEvent = nil
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            .copy
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            model?.finishExternalDraggingSession(wasDropped: operation != [])
        }
    }
}

struct ClearSelectionClickTarget: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeNSView(context: Context) -> NSView {
        let view = ClearSelectionView()
        view.model = model
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ClearSelectionView)?.model = model
    }

    final class ClearSelectionView: NSView {
        weak var model: AppModel?

        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }

        override func mouseDown(with event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !flags.contains(.shift),
                  !flags.contains(.command) else {
                return
            }
            model?.clearSelection()
        }
    }
}

enum MediaViewMode: String, CaseIterable, Identifiable {
    case list
    case thumbnails

    var id: String { rawValue }

    var label: String {
        switch self {
        case .list:
            return "List"
        case .thumbnails:
            return "Thumbnails"
        }
    }
}

enum MediaKindFilter: String, CaseIterable, Identifiable {
    case all
    case movie
    case jpeg
    case raw
    case sound

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:
            return "All"
        case .movie:
            return "Movie"
        case .jpeg:
            return "JPEG"
        case .raw:
            return "RAW"
        case .sound:
            return "Sound"
        }
    }

    func includes(_ item: MediaItem) -> Bool {
        let ext = (item.fileName as NSString).pathExtension.uppercased()
        switch self {
        case .all:
            return true
        case .movie:
            return ext == "MP4" || ext == "MOV"
        case .jpeg:
            return ext == "JPG" || ext == "JPEG"
        case .raw:
            return ext == "GPR" || item.mediaType == "RAW"
        case .sound:
            return ext == "WAV" || ext == "M4A" || ext == "AAC"
        }
    }
}

enum MediaSortKey: String, CaseIterable, Identifiable {
    case name
    case created
    case kind
    case size

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name:
            return "Name"
        case .created:
            return "Date"
        case .kind:
            return "Type"
        case .size:
            return "Size"
        }
    }
}

enum MediaDragPayload {
    static let type = UTType(exportedAs: "local.camera-transfer.media-item")
    static let filePromiseTypeIdentifiers = [
        "com.apple.NSFilePromiseItemMetaData",
        "com.apple.pasteboard.promised-file-name",
        "com.apple.pasteboard.promised-suggested-file-name",
        "com.apple.pasteboard.promised-file-content-type",
        "com.apple.pasteboard.NSFilePromiseID"
    ]
    static let dropTypeIdentifiers = [type.identifier] + filePromiseTypeIdentifiers

    static func pasteboardItem(for itemIDs: [MediaItem.ID], suggestedName: String) -> NSPasteboardItem {
        let pasteboardItem = NSPasteboardItem()
        let payload = DraggedMediaItemIDs(itemIDs: itemIDs)
        let data = (try? JSONEncoder().encode(payload)) ?? Data(itemIDs.joined(separator: "\n").utf8)
        pasteboardItem.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        pasteboardItem.setString(suggestedDragName(for: suggestedName), forType: .string)
        return pasteboardItem
    }

    static func provider(
        for item: MediaItem,
        draggedItemIDs: [MediaItem.ID],
        externalSelectionItems: [ExternalDragSelectionItem],
        sourceURL: URL?,
        promisedName: String,
        externalCancelHandler: @escaping @MainActor (@escaping @Sendable () -> Void) -> Void,
        statusHandler: @escaping @Sendable (ExternalDragEvent) -> Void
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        let payload = DraggedMediaItemIDs(itemIDs: draggedItemIDs.isEmpty ? [item.id] : draggedItemIDs)
        let data = (try? JSONEncoder().encode(payload)) ?? Data(item.id.utf8)
        provider.suggestedName = suggestedDragName(for: promisedName)
        provider.registerDataRepresentation(
            forTypeIdentifier: type.identifier,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }

        if externalSelectionItems.count > 1 {
            return provider
        }

        if item.isGroupedPhoto {
            guard let sourceURL else {
                statusHandler(.failed(
                    fileName: item.fileName,
                    message: "Could not prepare grouped photo sequence.",
                    isConnectionLost: false
                ))
                return provider
            }

            provider.registerFileRepresentation(
                forTypeIdentifier: UTType.folder.identifier,
                fileOptions: [],
                visibility: .all
            ) { completion in
                let transfer = GroupedPhotoExternalDragTransfer(
                    item: item,
                    sourceURL: sourceURL,
                    folderName: promisedName,
                    statusHandler: statusHandler
                )
                let task = Task {
                    do {
                        let folderURL = try await transfer.start()
                        completion(folderURL, false, nil)
                    } catch {
                        completion(nil, false, error)
                    }
                }
                let cancelTransfer: @Sendable () -> Void = {
                    task.cancel()
                    transfer.cancel()
                }
                Task { @MainActor in
                    externalCancelHandler(cancelTransfer)
                }
                transfer.progress.cancellationHandler = cancelTransfer
                return transfer.progress
            }
            return provider
        }

        if let sourceURL {
            let fileType = UTType(filenameExtension: (item.fileName as NSString).pathExtension) ?? .data
            provider.registerFileRepresentation(
                forTypeIdentifier: fileType.identifier,
                fileOptions: [],
                visibility: .all
            ) { completion in
                let transfer = ExternalDragTransfer(
                    item: item,
                    sourceURL: sourceURL,
                    fileName: promisedName,
                    expectedSize: item.sizeBytes,
                    statusHandler: statusHandler
                )
                let task = Task {
                    do {
                        let fileURL = try await transfer.start()
                        completion(fileURL, false, nil)
                    } catch {
                        completion(nil, false, error)
                    }
                }
                let cancelTransfer: @Sendable () -> Void = {
                    task.cancel()
                    transfer.cancel()
                }
                Task { @MainActor in
                    externalCancelHandler(cancelTransfer)
                }
                transfer.progress.cancellationHandler = cancelTransfer
                return transfer.progress
            }
        }

        return provider
    }

    private static func suggestedDragName(for fileName: String) -> String {
        let baseName = (fileName as NSString).deletingPathExtension
        return baseName.isEmpty ? fileName : baseName
    }
}

struct DraggedMediaItemIDs: Codable {
    let itemIDs: [MediaItem.ID]
}

struct ExternalDragSelectionItem: Sendable {
    let item: MediaItem
    let sourceURL: URL
    let promisedName: String
}

enum ExternalDragEvent: Sendable {
    case started(fileName: String, expectedSize: Int64)
    case progressed(writtenBytes: Int64, expectedSize: Int64)
    case finished(fileName: String, bytes: Int64)
    case failed(fileName: String, message: String, isConnectionLost: Bool)
    case canceled(fileName: String)
}

final class ExternalFilePromiseCoordinator: @unchecked Sendable {
    let displayName: String

    private let totalFiles: Int
    private var totalBytes: Int64
    private let statusHandler: @Sendable (ExternalDragEvent) -> Void
    private let queueHandler: @Sendable (MediaItem.ID, TransferQueueStatus, String?) -> Void
    private let lock = NSLock()

    private var delegates: [UUID: ExternalFilePromiseDelegate] = [:]
    private var fileProgress: [UUID: Int64] = [:]
    private var expectedSizes: [UUID: Int64] = [:]
    private var completedBytes: Int64 = 0
    private var completedFiles = 0
    private var didStart = false
    private var didEnd = false

    init(
        displayName: String,
        totalFiles: Int,
        totalBytes: Int64,
        statusHandler: @escaping @Sendable (ExternalDragEvent) -> Void,
        queueHandler: @escaping @Sendable (MediaItem.ID, TransferQueueStatus, String?) -> Void
    ) {
        self.displayName = displayName
        self.totalFiles = totalFiles
        self.totalBytes = totalBytes
        self.statusHandler = statusHandler
        self.queueHandler = queueHandler
    }

    func retain(_ delegate: ExternalFilePromiseDelegate) {
        lock.withLock {
            delegates[delegate.id] = delegate
        }
    }

    func recordExpectedSize(delegateID: UUID, expectedSize: Int64) {
        lock.withLock {
            guard !didEnd else { return }
            totalBytes += expectedSize
            expectedSizes[delegateID] = expectedSize
            fileProgress[delegateID] = 0
        }
    }

    func markStarted() {
        lock.withLock {
            guard !didStart, !didEnd else { return }
            didStart = true
        }
    }

    func updateProgress(delegateID: UUID, writtenBytes: Int64) {
        let expectedSize = lock.withLock { () -> Int64 in
            guard !didEnd else { return expectedSizes[delegateID] ?? totalBytes }
            fileProgress[delegateID] = writtenBytes
            return expectedSizes[delegateID] ?? totalBytes
        }
        statusHandler(.progressed(writtenBytes: writtenBytes, expectedSize: expectedSize))
    }

    func start(delegateID: UUID, itemID: MediaItem.ID, fileName: String) {
        let expectedSize = lock.withLock { () -> Int64? in
            guard !didEnd else { return nil }
            fileProgress[delegateID] = 0
            return expectedSizes[delegateID] ?? totalBytes
        }
        if let expectedSize {
            statusHandler(.started(fileName: fileName, expectedSize: expectedSize))
        }
        queueHandler(itemID, .active, "Finder")
    }

    func finish(delegateID: UUID, itemID: MediaItem.ID, bytes: Int64) {
        let finished: (Bool, Int64, Int64?) = lock.withLock {
            guard !didEnd else { return (false, completedBytes, nil) }
            let expectedSize = expectedSizes[delegateID]
            delegates[delegateID] = nil
            fileProgress[delegateID] = nil
            expectedSizes[delegateID] = nil
            completedBytes += bytes
            completedFiles += 1
            if completedFiles >= totalFiles {
                didEnd = true
                return (true, completedBytes, expectedSize)
            }
            return (false, completedBytes, expectedSize)
        }
        queueHandler(itemID, .done, "Size OK")
        if let expectedSize = finished.2 {
            statusHandler(.progressed(writtenBytes: bytes, expectedSize: expectedSize))
        }
        if finished.0 {
            statusHandler(.finished(fileName: displayName, bytes: finished.1))
        }
    }

    func fail(delegateID: UUID, itemID: MediaItem.ID, fileName: String, error: Error) {
        let shouldSend = lock.withLock { () -> Bool in
            delegates[delegateID] = nil
            fileProgress[delegateID] = nil
            expectedSizes[delegateID] = nil
            guard !didEnd else { return false }
            didEnd = true
            return true
        }
        queueHandler(itemID, .failed, error.localizedDescription)
        if shouldSend {
            statusHandler(.failed(
                fileName: fileName,
                message: error.localizedDescription,
                isConnectionLost: isCameraConnectionLoss(error)
            ))
        }
    }

    func cancel() {
        let delegatesToCancel = lock.withLock { () -> [ExternalFilePromiseDelegate] in
            guard !didEnd else { return [] }
            didEnd = true
            return Array(delegates.values)
        }
        delegatesToCancel.forEach { delegate in
            queueHandler(delegate.itemID, .canceled, "Canceled")
        }
        delegatesToCancel.forEach { $0.cancel() }
        statusHandler(.canceled(fileName: displayName))
    }
}

final class ExternalFilePromiseCompletion: @unchecked Sendable {
    private let handler: (Error?) -> Void

    init(_ handler: @escaping (Error?) -> Void) {
        self.handler = handler
    }

    func callAsFunction(_ error: Error?) {
        handler(error)
    }
}

final class ExternalFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let id = UUID()
    var itemID: MediaItem.ID { item.id }

    private let item: MediaItem
    private let sourceURL: URL
    private let promisedName: String
    private let expectedSize: Int64?
    private let coordinator: ExternalFilePromiseCoordinator
    private let lock = NSLock()

    private var task: Task<Void, Never>?
    private var delegate: StreamingDownloadDelegate?
    private var session: URLSession?

    init(
        item: MediaItem,
        sourceURL: URL,
        promisedName: String,
        expectedSize: Int64?,
        coordinator: ExternalFilePromiseCoordinator
    ) {
        self.item = item
        self.sourceURL = sourceURL
        self.promisedName = promisedName
        self.expectedSize = expectedSize
        self.coordinator = coordinator
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        promisedName
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo destinationURL: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let completion = ExternalFilePromiseCompletion(completionHandler)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let bytes = try await self.writePromise(to: destinationURL)
                self.coordinator.finish(delegateID: self.id, itemID: self.itemID, bytes: bytes)
                completion(nil)
            } catch is CancellationError {
                self.coordinator.cancel()
                completion(CancellationError())
            } catch let error as URLError where error.code == .cancelled {
                self.coordinator.cancel()
                completion(CancellationError())
            } catch {
                self.coordinator.fail(delegateID: self.id, itemID: self.itemID, fileName: self.promisedName, error: error)
                completion(error)
            }
        }
        lock.withLock {
            self.task = task
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }

    func cancel() {
        let state: (Task<Void, Never>?, StreamingDownloadDelegate?, URLSession?) = lock.withLock {
            (task, delegate, session)
        }
        state.0?.cancel()
        state.1?.cancel()
        state.2?.invalidateAndCancel()
    }

    private func writePromise(to destinationURL: URL) async throws -> Int64 {
        try await withExclusiveTransfer {
            try await writePromiseWithoutOverlap(to: destinationURL)
        }
    }

    private func writePromiseWithoutOverlap(to destinationURL: URL) async throws -> Int64 {
        let resolvedExpectedSize: Int64
        if let expectedSize {
            resolvedExpectedSize = expectedSize
        } else {
            resolvedExpectedSize = try await fetchRequiredDownloadSize(from: sourceURL)
        }
        coordinator.recordExpectedSize(delegateID: id, expectedSize: resolvedExpectedSize)
        coordinator.markStarted()
        coordinator.start(delegateID: id, itemID: itemID, fileName: promisedName)
        let destinationFolder = destinationURL.deletingLastPathComponent()
        try ensureExternalFreeSpace(in: destinationFolder, requiredBytes: resolvedExpectedSize)

        let requestedDestination = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(promisedName)
        let resolvedDestination = try await MainActor.run {
            try resolveDestinationForWrite(original: requestedDestination)
        }
        let finalDestination = resolvedDestination.url
        let partialDestination = externalPartialURL(for: finalDestination)

        do {
            var request = URLRequest(url: sourceURL)
            request.timeoutInterval = 60 * 60 * 6

            let delegate = StreamingDownloadDelegate(
                destination: partialDestination,
                expectedSize: resolvedExpectedSize,
                progressHandler: { [weak self] writtenBytes, _ in
                    guard let self else { return }
                    self.coordinator.updateProgress(delegateID: self.id, writtenBytes: writtenBytes)
                }
            )
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: queue)

            lock.withLock {
                self.delegate = delegate
                self.session = session
            }

            defer {
                session.invalidateAndCancel()
                lock.withLock {
                    self.delegate = nil
                    self.session = nil
                    self.task = nil
                }
            }

            let result = try await withTaskCancellationHandler {
                try await delegate.start(request: request, session: session)
            } onCancel: {
                delegate.cancel()
            }
            try Task.checkCancellation()

            let actualSize = try fileSize(at: partialDestination)
            try validateDownloadedSize(
                actualSize: actualSize,
                listedSize: resolvedExpectedSize,
                responseSize: result.responseExpectedBytes
            )
            if resolvedDestination.replacesExistingFile,
               FileManager.default.fileExists(atPath: finalDestination.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: finalDestination)
            }
            try FileManager.default.moveItem(at: partialDestination, to: finalDestination)
            return actualSize
        } catch is CancellationError {
            removePartialFileAfterUserCancel(partialDestination)
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            removePartialFileAfterUserCancel(partialDestination)
            throw CancellationError()
        }
    }
}

struct GroupedPhotoMember: Sendable {
    let fileName: String
    let sourceURL: URL
    let expectedSize: Int64
}

struct DownloadResult: Sendable {
    let writtenBytes: Int64
    let responseExpectedBytes: Int64?
}

struct PartialFile: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let sizeBytes: Int64?

    var id: String {
        url.path(percentEncoded: false)
    }

    var displayName: String {
        url.lastPathComponent
    }

    var sizeDescription: String {
        sizeBytes.map(formatBytes) ?? "Unknown"
    }
}

enum TransferQueueStatus: String, Sendable {
    case pending
    case active
    case done
    case failed
    case canceled

    var isTerminal: Bool {
        switch self {
        case .done, .failed, .canceled:
            return true
        case .pending, .active:
            return false
        }
    }

    var label: String {
        switch self {
        case .pending:
            return "Queued"
        case .active:
            return "Transferring"
        case .done:
            return "Done"
        case .failed:
            return "Failed"
        case .canceled:
            return "Canceled"
        }
    }
}

struct TransferQueueEntry: Identifiable, Sendable {
    let id = UUID()
    let item: MediaItem
    var status: TransferQueueStatus
    var message: String?
    var isExternalDrag = false
}

struct TransferLogEntry: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let message: String

    var timeText: String {
        DateFormatter.transferLogTime.string(from: date)
    }
}

extension DateFormatter {
    static let transferLogTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

final class ExternalDragTransfer: @unchecked Sendable {
    let progress: Progress

    private let item: MediaItem
    private let sourceURL: URL
    private let fileName: String
    private let expectedSize: Int64?
    private let statusHandler: @Sendable (ExternalDragEvent) -> Void
    private let lock = NSLock()

    private var delegate: StreamingDownloadDelegate?
    private var session: URLSession?

    init(
        item: MediaItem,
        sourceURL: URL,
        fileName: String,
        expectedSize: Int64?,
        statusHandler: @escaping @Sendable (ExternalDragEvent) -> Void
    ) {
        self.item = item
        self.sourceURL = sourceURL
        self.fileName = fileName
        self.expectedSize = expectedSize
        self.statusHandler = statusHandler
        progress = Progress(totalUnitCount: expectedSize ?? 1)
    }

    func start() async throws -> URL {
        try await withExclusiveTransfer {
            try await startWithoutOverlappingTransfer()
        }
    }

    private func startWithoutOverlappingTransfer() async throws -> URL {
        let resolvedExpectedSize: Int64
        if let expectedSize {
            resolvedExpectedSize = expectedSize
        } else {
            resolvedExpectedSize = try await fetchRequiredDownloadSize(from: sourceURL)
            progress.totalUnitCount = resolvedExpectedSize
        }
        statusHandler(.started(fileName: fileName, expectedSize: resolvedExpectedSize))

        do {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("CameraTransferDrag-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let finalURL = folder.appendingPathComponent(fileName)
            let partialURL = folder.appendingPathComponent("\(fileName).partial")

            var request = URLRequest(url: sourceURL)
            request.timeoutInterval = 60 * 60 * 6
            let delegate = StreamingDownloadDelegate(
                destination: partialURL,
                expectedSize: resolvedExpectedSize,
                progressHandler: { [weak self] writtenBytes, expectedSize in
                    guard let self, let expectedSize else { return }
                    self.progress.completedUnitCount = writtenBytes
                    self.statusHandler(.progressed(writtenBytes: writtenBytes, expectedSize: expectedSize))
                }
            )
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: queue)

            lock.withLock {
                self.delegate = delegate
                self.session = session
            }

            defer {
                session.invalidateAndCancel()
                lock.withLock {
                    self.delegate = nil
                    self.session = nil
                }
            }

            let downloadResult = try await withTaskCancellationHandler {
                try await delegate.start(request: request, session: session)
            } onCancel: {
                delegate.cancel()
            }
            try Task.checkCancellation()

            let actualSize = try fileSize(at: partialURL)
            try validateDownloadedSize(
                actualSize: actualSize,
                listedSize: resolvedExpectedSize,
                responseSize: downloadResult.responseExpectedBytes
            )

            try FileManager.default.moveItem(at: partialURL, to: finalURL)
            progress.completedUnitCount = resolvedExpectedSize
            statusHandler(.finished(fileName: fileName, bytes: actualSize))
            return finalURL
        } catch is CancellationError {
            statusHandler(.canceled(fileName: fileName))
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            statusHandler(.canceled(fileName: fileName))
            throw CancellationError()
        } catch {
            statusHandler(.failed(
                fileName: fileName,
                message: error.localizedDescription,
                isConnectionLost: isCameraConnectionLoss(error)
            ))
            throw error
        }
    }

    func cancel() {
        let state: (StreamingDownloadDelegate?, URLSession?) = lock.withLock {
            (self.delegate, self.session)
        }
        let (delegate, session) = state
        delegate?.cancel()
        session?.invalidateAndCancel()
    }
}

final class GroupedPhotoExternalDragTransfer: @unchecked Sendable {
    let progress = Progress(totalUnitCount: 1)

    private let item: MediaItem
    private let sourceURL: URL
    private let folderName: String
    private let statusHandler: @Sendable (ExternalDragEvent) -> Void
    private let lock = NSLock()

    private var delegate: StreamingDownloadDelegate?
    private var session: URLSession?

    init(
        item: MediaItem,
        sourceURL: URL,
        folderName: String,
        statusHandler: @escaping @Sendable (ExternalDragEvent) -> Void
    ) {
        self.item = item
        self.sourceURL = sourceURL
        self.folderName = folderName
        self.statusHandler = statusHandler
    }

    func start() async throws -> URL {
        try await withExclusiveTransfer {
            try await startWithoutOverlappingTransfer()
        }
    }

    private func startWithoutOverlappingTransfer() async throws -> URL {
        do {
            let members = try await groupedPhotoMembers(for: item, sourceURL: sourceURL, includeRAW: true)
            let totalBytes = members.reduce(Int64(0)) { $0 + $1.expectedSize }
            let firstExpectedSize = members.first?.expectedSize ?? totalBytes
            progress.totalUnitCount = max(firstExpectedSize, 1)
            statusHandler(.started(fileName: folderName, expectedSize: firstExpectedSize))

            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("CameraTransferDrag-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            let finalFolder = root.appendingPathComponent(folderName, isDirectory: true)
            let partialFolder = root.appendingPathComponent("\(folderName).partial", isDirectory: true)
            try FileManager.default.createDirectory(at: partialFolder, withIntermediateDirectories: true)

            var completedBytes: Int64 = 0
            for member in members {
                try Task.checkCancellation()
                let destination = partialFolder.appendingPathComponent(member.fileName)
                let partialDestination = partialFolder.appendingPathComponent("\(member.fileName).partial")
                progress.totalUnitCount = max(member.expectedSize, 1)
                progress.completedUnitCount = 0
                statusHandler(.progressed(writtenBytes: 0, expectedSize: member.expectedSize))
                let result = try await download(member: member, to: partialDestination)
                let actualSize = try fileSize(at: partialDestination)
                try validateDownloadedSize(
                    actualSize: actualSize,
                    listedSize: member.expectedSize,
                    responseSize: result.responseExpectedBytes
                )
                try FileManager.default.moveItem(at: partialDestination, to: destination)
                completedBytes += actualSize
                progress.completedUnitCount = actualSize
                statusHandler(.progressed(writtenBytes: actualSize, expectedSize: member.expectedSize))
            }

            try FileManager.default.moveItem(at: partialFolder, to: finalFolder)
            statusHandler(.finished(fileName: folderName, bytes: completedBytes))
            return finalFolder
        } catch is CancellationError {
            statusHandler(.canceled(fileName: folderName))
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            statusHandler(.canceled(fileName: folderName))
            throw CancellationError()
        } catch {
            statusHandler(.failed(
                fileName: folderName,
                message: error.localizedDescription,
                isConnectionLost: isCameraConnectionLoss(error)
            ))
            throw error
        }
    }

    func cancel() {
        let state: (StreamingDownloadDelegate?, URLSession?) = lock.withLock {
            (self.delegate, self.session)
        }
        let (delegate, session) = state
        delegate?.cancel()
        session?.invalidateAndCancel()
    }

    private func download(
        member: GroupedPhotoMember,
        to destination: URL
    ) async throws -> DownloadResult {
        var request = URLRequest(url: member.sourceURL)
        request.timeoutInterval = 60 * 60 * 6

        let delegate = StreamingDownloadDelegate(
            destination: destination,
            expectedSize: member.expectedSize,
            progressHandler: { [weak self] writtenBytes, _ in
                guard let self else { return }
                self.progress.completedUnitCount = writtenBytes
                self.statusHandler(.progressed(writtenBytes: writtenBytes, expectedSize: member.expectedSize))
            }
        )
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: queue)

        lock.withLock {
            self.delegate = delegate
            self.session = session
        }

        defer {
            session.invalidateAndCancel()
            lock.withLock {
                self.delegate = nil
                self.session = nil
            }
        }

        return try await withTaskCancellationHandler {
            try await delegate.start(request: request, session: session)
        } onCancel: {
            delegate.cancel()
        }
    }
}

struct ThumbnailTile: View {
    let item: MediaItem
    let thumbnailURL: URL?
    let isSelected: Bool
    let thumbnailSize: CGFloat
    let playbackPlayer: AVPlayer?
    let isPlaybackPaused: Bool
    let isPlaybackStarting: Bool
    let showsPlayButton: Bool
    @ObservedObject var model: AppModel
    let playAction: () -> Void
    let stopAction: () -> Void
    let resumeAction: () -> Void

    var body: some View {
        let thumbnailHeight = thumbnailSize * 9 / 16

        return ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        if let playbackPlayer {
                            InlineVideoPlayerView(player: playbackPlayer)
                        } else {
                            thumbnail
                                .aspectRatio(16 / 9, contentMode: .fit)
                        }
                    }
                    .frame(width: thumbnailSize, height: thumbnailHeight)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    if playbackPlayer == nil && item.isOver4GiB {
                        Text("Large")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.18))
                            .foregroundStyle(.orange)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .padding(5)
                    }
                }

                HStack(spacing: 6) {
                    Text(item.fileName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(item.createdDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(item.sizeDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: thumbnailSize, alignment: .leading)
            .contentShape(Rectangle())

            if playbackPlayer == nil {
                ExternalDragSource(model: model, item: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if showsPlayButton && playbackPlayer == nil {
                Button(action: playAction) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .position(x: thumbnailSize / 2, y: thumbnailHeight / 2)
                .help("Preview")
            }

            if playbackPlayer != nil {
                if isPlaybackStarting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 42, height: 42)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Circle())
                        .position(x: thumbnailSize / 2, y: thumbnailHeight / 2)
                        .help("Loading preview")
                } else {
                    Button(action: isPlaybackPaused ? resumeAction : stopAction) {
                        Image(systemName: isPlaybackPaused ? "play.fill" : "stop.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(Color.black.opacity(0.55))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .position(x: thumbnailSize / 2, y: thumbnailHeight / 2)
                    .help(isPlaybackPaused ? "Resume preview" : "Stop preview")
                }
            }
        }
        .frame(width: thumbnailSize, height: thumbnailHeight + 66, alignment: .topLeading)
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .windowBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let thumbnailURL {
            CachedThumbnailImage(url: thumbnailURL) {
                placeholder
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .controlBackgroundColor))
            Text(item.fileName.pathExtensionLabel)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
final class VideoPlaybackStore: ObservableObject {
    @Published private(set) var activeItemID: MediaItem.ID?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isPaused = false
    @Published private(set) var isStarting = false
    private var playbackMonitorTask: Task<Void, Never>?

    func play(itemID: MediaItem.ID, url: URL) {
        if activeItemID != itemID || player == nil {
            player?.pause()
            playbackMonitorTask?.cancel()
            player = AVPlayer(url: url)
            activeItemID = itemID
        }
        isPaused = false
        isStarting = true
        player?.play()
        monitorPlaybackStart(for: itemID)
    }

    func pause() {
        isPaused = true
        isStarting = false
        playbackMonitorTask?.cancel()
        enforcePause()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard self?.isPaused == true else { return }
            self?.enforcePause()
        }
    }

    func resume() {
        isPaused = false
        isStarting = true
        player?.play()
        if let activeItemID {
            monitorPlaybackStart(for: activeItemID)
        }
    }

    private func enforcePause() {
        guard let player else { return }
        player.pause()
        player.rate = 0
        player.cancelPendingPrerolls()
        player.currentItem?.cancelPendingSeeks()
    }

    private func monitorPlaybackStart(for itemID: MediaItem.ID) {
        playbackMonitorTask?.cancel()
        playbackMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self,
                      self.activeItemID == itemID,
                      !self.isPaused else {
                    return
                }
                if self.player?.timeControlStatus == .playing {
                    self.isStarting = false
                    return
                }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }
}

struct InlineVideoPlayerView: View {
    let player: AVPlayer

    var body: some View {
        AVPlayerPreviewView(player: player)
            .background(Color.black)
    }
}

struct AVPlayerPreviewView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

@MainActor
final class ThumbnailImageCache {
    static let shared = ThumbnailImageCache()

    private let cache = NSCache<NSURL, NSImage>()
    private var inFlightTasks: [URL: Task<Data, Error>] = [:]

    private init() {
        cache.countLimit = 600
    }

    func image(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func dataLoadingTask(for url: URL) -> Task<Data, Error>? {
        guard image(for: url) == nil else {
            return nil
        }
        if let task = inFlightTasks[url] {
            return task
        }

        let task = Task { () throws -> Data in
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                throw AppError.message("Thumbnail returned HTTP \(http.statusCode).")
            }
            return data
        }
        inFlightTasks[url] = task
        return task
    }

    func store(_ image: NSImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
        inFlightTasks[url] = nil
    }

    func discardTask(for url: URL) {
        inFlightTasks[url] = nil
    }

    func removeAll() {
        cache.removeAllObjects()
        inFlightTasks.values.forEach { $0.cancel() }
        inFlightTasks.removeAll()
    }
}

struct CachedThumbnailImage<Placeholder: View>: View {
    let url: URL
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var loadedImage: NSImage?
    @State private var didFail = false

    var body: some View {
        if let image = loadedImage ?? ThumbnailImageCache.shared.image(for: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else if didFail {
            placeholder()
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: url) {
                    await loadThumbnail()
                }
        }
    }

    private func loadThumbnail() async {
        if let cachedImage = ThumbnailImageCache.shared.image(for: url) {
            loadedImage = cachedImage
            didFail = false
            return
        }

        guard let task = ThumbnailImageCache.shared.dataLoadingTask(for: url) else {
            return
        }
        do {
            let data = try await task.value
            guard let image = NSImage(data: data) else {
                throw AppError.message("Could not read thumbnail image.")
            }
            ThumbnailImageCache.shared.store(image, for: url)
            loadedImage = image
            didFail = false
        } catch is CancellationError {
        } catch {
            ThumbnailImageCache.shared.discardTask(for: url)
            didFail = true
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var baseURL = "http://172.27.113.51:8080"
    @Published var items: [MediaItem] = []
    @Published var selectedItemID: MediaItem.ID?
    @Published var sortKey: MediaSortKey = .created
    @Published var sortAscending = false
    @Published var mediaKindFilter: MediaKindFilter = .all
    @Published var saveFolder: URL?
    @Published var status = "Connect the camera, then press Connect."
    @Published var statusIsError = false
    @Published var isBusy = false
    @Published var isConnected = false
    @Published var isTransferring = false
    @Published var transferProgress = 0.0
    @Published var transferProgressText = ""
    @Published var partialFiles: [PartialFile] = []
    @Published var selectedItemIDs = Set<MediaItem.ID>()
    @Published var transferQueue: [TransferQueueEntry] = []
    @Published var transferLog: [TransferLogEntry] = []
    @Published var autoLaunchOnCameraConnection = false
    @Published var autoLaunchStatus = "Off"
    @Published var autoLaunchStatusIsError = false
    @Published private(set) var autoConnectPaused = false

    private var currentTransferTask: Task<Void, Never>?
    private var currentExternalDragCancel: (@Sendable () -> Void)?
    private var activeExternalPromiseCoordinator: ExternalFilePromiseCoordinator?
    private var currentInternalDragItemIDs: [MediaItem.ID] = []
    private var deferredSizeRefreshTask: Task<Void, Never>?
    private var isMonitoringConnection = false
    private var pausedUSBURLCandidates = Set<String>()
    private var sawUSBDisconnectAfterEject = false
    private let fallbackConnectionCandidates = [
        "http://172.27.113.51:8080",
        "http://10.5.5.9:8080"
    ]
    struct CompanionMediaCandidate: Sendable {
        let fileName: String
        let baseItem: MediaItem
        let mediaType: String
    }

    init() {
        do {
            try CameraAutoLaunchAgent.migrateLegacyInstallIfNeeded(appURL: Bundle.main.bundleURL)
        } catch {
            autoLaunchStatusIsError = true
            autoLaunchStatus = "Auto launch migration failed: \(error.localizedDescription)"
        }
        autoLaunchOnCameraConnection = CameraAutoLaunchAgent.isInstalled()
        UserDefaults.standard.set(autoLaunchOnCameraConnection, forKey: Self.autoLaunchDefaultsKey)
        if !autoLaunchStatusIsError {
            autoLaunchStatus = autoLaunchOnCameraConnection
                ? "On"
                : "Off"
        }
    }

    private static let autoLaunchDefaultsKey = "autoLaunchOnCameraConnection"

    var selectedItem: MediaItem? {
        items.first { $0.id == selectedItemID }
    }

    var hasSelection: Bool {
        !selectedItemIDs.isEmpty
    }

    var canStartManualTransfer: Bool {
        selectedItemID != nil || !selectedItemIDs.isEmpty
    }

    var transferUnavailableReason: String? {
        if !isConnected {
            return "Connect the camera before transferring."
        }
        if saveFolder == nil {
            return "Choose a save folder before transferring."
        }
        if !canStartManualTransfer {
            return "Select one or more files before transferring."
        }
        if isBusy && !isTransferring {
            return "Wait for the current task to finish."
        }
        return nil
    }

    var selectionSummary: String {
        let visibleItems = sortedItems
        let visibleIDs = Set(visibleItems.map(\.id))
        let selectedVisibleCount = selectedItemIDs.intersection(visibleIDs).count
        guard !selectedItemIDs.isEmpty else {
            return "\(visibleItems.count) items"
        }
        return "\(selectedVisibleCount) of \(visibleItems.count) selected"
    }

    var selectedTransferCountText: String {
        let count = selectedTransferItems.count
        return count == 1 ? "1 selected" : "\(count) selected"
    }

    var selectedTransferSizeText: String {
        let selectedItems = selectedTransferItems
        guard !selectedItems.isEmpty else {
            return "Choose files"
        }
        let knownBytes = selectedItems.compactMap(\.sizeBytes).reduce(Int64(0), +)
        guard knownBytes > 0 else {
            return "Size pending"
        }
        if selectedItems.contains(where: { $0.sizeBytes == nil }) {
            return "\(formatBytes(knownBytes)) + pending size"
        }
        return "\(formatBytes(knownBytes)) total"
    }

    private var selectedTransferItems: [MediaItem] {
        let selectedIDs = selectedItemIDs
        guard !selectedIDs.isEmpty else {
            if let selectedItem {
                return [selectedItem]
            }
            return []
        }
        return sortedItems.filter { selectedIDs.contains($0.id) }
    }

    var transferQueueSummary: String {
        let activeCount = transferQueue.filter { $0.status == .active }.count
        let pendingCount = transferQueue.filter { $0.status == .pending }.count
        let visibleCount = activeCount + pendingCount
        if activeCount > 0 {
            return "\(visibleCount) in queue · \(activeCount) transferring · \(pendingCount) waiting"
        }
        return "\(visibleCount) in queue · \(pendingCount) waiting"
    }

    var sortedItems: [MediaItem] {
        items.filter { mediaKindFilter.includes($0) }.sorted { lhs, rhs in
            let result: ComparisonResult
            switch sortKey {
            case .name:
                result = lhs.path.localizedStandardCompare(rhs.path)
            case .created:
                result = compareOptional(lhs.createdTimestamp, rhs.createdTimestamp)
            case .kind:
                result = lhs.kindDescription.localizedStandardCompare(rhs.kindDescription)
            case .size:
                result = compareOptional(lhs.sizeBytes, rhs.sizeBytes)
            }
            return sortAscending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    var connectionLabel: String {
        if autoConnectPaused {
            return "Ready to unplug"
        }
        return isConnected ? "Camera connected" : "No camera"
    }

    func setAutoLaunchOnCameraConnection(_ enabled: Bool) {
        do {
            if enabled {
                try CameraAutoLaunchAgent.install(appURL: Bundle.main.bundleURL)
                autoLaunchOnCameraConnection = true
                autoLaunchStatus = "On"
                setStatus("Auto launch enabled.")
            } else {
                try CameraAutoLaunchAgent.uninstall()
                autoLaunchOnCameraConnection = false
                autoLaunchStatus = "Off"
                setStatus("Auto launch disabled.")
            }
            autoLaunchStatusIsError = false
            UserDefaults.standard.set(autoLaunchOnCameraConnection, forKey: Self.autoLaunchDefaultsKey)
        } catch {
            autoLaunchOnCameraConnection = CameraAutoLaunchAgent.isInstalled()
            autoLaunchStatusIsError = true
            autoLaunchStatus = "Could not update auto launch. \(error.localizedDescription)"
            UserDefaults.standard.set(autoLaunchOnCameraConnection, forKey: Self.autoLaunchDefaultsKey)
            setStatus(autoLaunchStatus, isError: true)
        }
    }

    func monitorCameraConnection() async {
        guard !isMonitoringConnection else { return }
        isMonitoringConnection = true
        defer {
            isMonitoringConnection = false
        }

        while !Task.isCancelled {
            if !autoConnectPaused,
               !isConnected,
               !isBusy,
               !isTransferring,
               !usbCameraURLCandidates().isEmpty {
                await autoConnect(showNotFoundError: false)
            }

            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
    }

    func dragProviderForSelection(startingAt item: MediaItem) -> NSItemProvider {
        if !selectedItemIDs.contains(item.id) {
            selectSingleItem(item.id)
        }

        let draggedIDs = sortedItems.map(\.id).filter { selectedItemIDs.contains($0) }
        currentInternalDragItemIDs = draggedIDs.isEmpty ? [item.id] : draggedIDs
        return dragProvider(for: item, draggedItemIDs: draggedIDs)
    }

    func externalDraggingItems(startingAt item: MediaItem, draggingFrame: NSRect) -> [NSDraggingItem] {
        if !selectedItemIDs.contains(item.id) {
            selectSingleItem(item.id)
        }

        let draggedIDs = sortedItems.map(\.id).filter { selectedItemIDs.contains($0) }
        let effectiveDraggedIDs = draggedIDs.isEmpty ? [item.id] : draggedIDs
        currentInternalDragItemIDs = effectiveDraggedIDs

        let selectionItems = externalDragSelectionItems(for: effectiveDraggedIDs)
        let regularFileItems = selectionItems.filter { !$0.item.isGroupedPhoto }

        guard regularFileItems.count == selectionItems.count else {
            let displayName = selectionItems.count == 1 ? selectionItems[0].item.fileName : "\(selectionItems.count) files"
            let draggingItem = internalDraggingItem(
                itemIDs: effectiveDraggedIDs,
                displayName: displayName,
                draggingFrame: draggingFrame
            )
            setStatus("Use Transfer for grouped photos.")
            return [draggingItem]
        }

        let displayName = regularFileItems.count == 1 ? regularFileItems[0].promisedName : "\(regularFileItems.count) files"
        let coordinator = ExternalFilePromiseCoordinator(
            displayName: displayName,
            totalFiles: regularFileItems.count,
            totalBytes: 0,
            statusHandler: { [weak self] event in
                Task { @MainActor in
                    self?.handleExternalDragEvent(event)
                }
            },
            queueHandler: { [weak self] itemID, status, message in
                Task { @MainActor in
                    self?.updateExternalDragQueueItem(itemID: itemID, status: status, message: message)
                }
            }
        )
        activeExternalPromiseCoordinator = coordinator
        currentExternalDragCancel = {
            coordinator.cancel()
        }
        prepareExternalDragQueueItems(for: regularFileItems.map(\.item))
        if regularFileItems.count > 1 {
            setStatus("Prepared \(regularFileItems.count) file(s) for Finder drag.")
        }

        let fileDraggingItems = regularFileItems.enumerated().map { index, selectionItem in
            let provider = filePromiseProvider(for: selectionItem, coordinator: coordinator)
            let draggingItem = NSDraggingItem(pasteboardWriter: provider)
            let offsetFrame = draggingFrame.offsetBy(dx: CGFloat(index + 1) * 3, dy: -CGFloat(index + 1) * 3)
            draggingItem.setDraggingFrame(offsetFrame, contents: Self.transparentDragImage)
            return draggingItem
        }

        return fileDraggingItems
    }

    private func internalDraggingItem(
        itemIDs: [MediaItem.ID],
        displayName: String,
        draggingFrame: NSRect
    ) -> NSDraggingItem {
        let pasteboardItem = MediaDragPayload.pasteboardItem(for: itemIDs, suggestedName: displayName)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(draggingFrame, contents: Self.transparentDragImage)
        return draggingItem
    }

    private static var transparentDragImage: NSImage {
        NSImage(size: NSSize(width: 1, height: 1))
    }

    private func filePromiseProvider(
        for selectionItem: ExternalDragSelectionItem,
        coordinator: ExternalFilePromiseCoordinator
    ) -> NSFilePromiseProvider {
        let fileType = UTType(filenameExtension: (selectionItem.promisedName as NSString).pathExtension) ?? .data
        let delegate = ExternalFilePromiseDelegate(
            item: selectionItem.item,
            sourceURL: selectionItem.sourceURL,
            promisedName: selectionItem.promisedName,
            expectedSize: selectionItem.item.sizeBytes,
            coordinator: coordinator
        )
        coordinator.retain(delegate)

        let provider = NSFilePromiseProvider(fileType: fileType.identifier, delegate: delegate)
        provider.userInfo = delegate.id.uuidString
        return provider
    }

    func finishExternalDraggingSession(wasDropped: Bool) {
        if !wasDropped {
            let draggedIDs = Set(currentInternalDragItemIDs)
            transferQueue.removeAll {
                draggedIDs.contains($0.item.id) && $0.isExternalDrag && $0.status == .pending
            }
            currentInternalDragItemIDs = []
        }
    }

    private func prepareExternalDragQueueItems(for items: [MediaItem]) {
        for item in items where !transferQueue.contains(where: { $0.item.id == item.id && $0.isExternalDrag }) {
            transferQueue.append(TransferQueueEntry(item: item, status: .pending, message: "Finder", isExternalDrag: true))
        }
    }

    private func updateExternalDragQueueItem(itemID: MediaItem.ID, status: TransferQueueStatus, message: String?) {
        guard let index = transferQueue.firstIndex(where: { $0.item.id == itemID && $0.isExternalDrag }) else {
            guard let item = items.first(where: { $0.id == itemID }) else {
                return
            }
            transferQueue.append(TransferQueueEntry(item: item, status: status, message: message, isExternalDrag: true))
            appendTransferLog("\(status.label): \(item.fileName)\(message.map { " / \($0)" } ?? "")")
            removeFinishedExternalDragQueueItems(itemID: itemID, status: status)
            return
        }
        transferQueue[index].status = status
        transferQueue[index].message = message
        appendTransferLog("\(status.label): \(transferQueue[index].item.fileName)\(message.map { " / \($0)" } ?? "")")
        removeFinishedExternalDragQueueItems(itemID: itemID, status: status)
    }

    private func removeFinishedExternalDragQueueItems(itemID: MediaItem.ID, status: TransferQueueStatus) {
        guard status.isTerminal else {
            return
        }
        transferQueue.removeAll { $0.item.id == itemID && $0.isExternalDrag }
    }

    private func dragProvider(for item: MediaItem, draggedItemIDs: [MediaItem.ID]) -> NSItemProvider {
        let sourceURL = try? mediaDownloadURL(for: item)
        let promisedName = finderPromisedName(for: item)
        let externalSelectionItems = externalDragSelectionItems(for: draggedItemIDs)
        return MediaDragPayload.provider(
            for: item,
            draggedItemIDs: draggedItemIDs,
            externalSelectionItems: externalSelectionItems,
            sourceURL: sourceURL,
            promisedName: promisedName,
            externalCancelHandler: { [weak self] cancel in
                self?.currentExternalDragCancel = cancel
            },
            statusHandler: { [weak self] event in
                Task { @MainActor in
                    self?.handleExternalDragEvent(event)
                }
            }
        )
    }

    private func externalDragSelectionItems(for itemIDs: [MediaItem.ID]) -> [ExternalDragSelectionItem] {
        itemIDs.compactMap { itemID in
            guard let item = items.first(where: { $0.id == itemID }),
                  let sourceURL = try? mediaDownloadURL(for: item) else {
                return nil
            }
            let promisedName = item.isGroupedPhoto ? groupedPhotoFolderName(for: item) : item.fileName
            return ExternalDragSelectionItem(item: item, sourceURL: sourceURL, promisedName: promisedName)
        }
    }

    private func finderPromisedName(for item: MediaItem) -> String {
        item.isGroupedPhoto ? groupedPhotoFolderName(for: item) : item.fileName
    }

    func isItemSelected(_ item: MediaItem) -> Bool {
        selectedItemIDs.contains(item.id)
    }

    func clearSelection() {
        selectedItemIDs.removeAll()
        selectedItemID = nil
        setStatus("Selection cleared.")
    }

    func copySelectedFileNames() {
        let selectedItems = selectedTransferCandidateIDs().compactMap { itemID in
            items.first { $0.id == itemID }
        }
        guard !selectedItems.isEmpty else {
            setStatus("Choose a file first.", isError: true)
            return
        }
        copyFileNames(selectedItems.map(\.fileName))
    }

    func copyFileName(_ item: MediaItem) {
        copyFileNames([item.fileName])
    }

    private func copyFileNames(_ fileNames: [String]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(fileNames.joined(separator: "\n"), forType: .string)
        setStatus(fileNames.count == 1 ? "Copied name: \(fileNames[0])" : "Copied \(fileNames.count) names.")
    }

    func selectAllItems() {
        selectedItemIDs = Set(sortedItems.map(\.id))
        selectedItemID = sortedItems.last?.id
        setStatus("Selected \(selectedItemIDs.count) file(s).")
    }

    func handleMediaSelection(_ item: MediaItem) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let selectedItemID {
            selectRange(from: selectedItemID, to: item.id)
            return
        }

        if flags.contains(.command) {
            if selectedItemIDs.contains(item.id) {
                selectedItemIDs.remove(item.id)
            } else {
                selectedItemIDs.insert(item.id)
            }
            selectedItemID = item.id
            return
        }

        selectSingleItem(item.id)
    }

    func toggleSelection(_ item: MediaItem) {
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
            if selectedItemID == item.id {
                selectedItemID = selectedItemIDs.first
            }
            setStatus(selectedItemIDs.isEmpty ? "Selection cleared." : "Selected \(selectedItemIDs.count) file(s).")
        } else {
            selectedItemIDs.insert(item.id)
            selectedItemID = item.id
            setStatus("Selected \(selectedItemIDs.count) file(s).")
        }
    }

    private func selectSingleItem(_ itemID: MediaItem.ID) {
        selectedItemID = itemID
        selectedItemIDs = [itemID]
    }

    private func selectRange(from startID: MediaItem.ID, to endID: MediaItem.ID) {
        selectedItemIDs.formUnion(idsInRange(from: startID, to: endID))
        selectedItemID = endID
    }

    private func idsInRange(from startID: MediaItem.ID, to endID: MediaItem.ID) -> Set<MediaItem.ID> {
        let visibleItems = sortedItems
        guard let startIndex = visibleItems.firstIndex(where: { $0.id == startID }),
              let endIndex = visibleItems.firstIndex(where: { $0.id == endID }) else {
            return [endID]
        }

        let range = min(startIndex, endIndex)...max(startIndex, endIndex)
        return Set(range.map { visibleItems[$0].id })
    }

    private func enqueueTransfers(itemIDs: [MediaItem.ID]) {
        guard saveFolder != nil else {
            setStatus("Choose a save folder first.", isError: true)
            return
        }

        let uniqueItemIDs = uniqueIDsPreservingOrder(itemIDs)
        let queuedItems = uniqueItemIDs.compactMap { itemID in
            items.first { $0.id == itemID }
        }
        guard !queuedItems.isEmpty else {
            setStatus("Choose a file first.", isError: true)
            return
        }

        transferQueue.append(contentsOf: queuedItems.map { item in
            TransferQueueEntry(item: item, status: .pending, message: nil)
        })
        appendTransferLog("Queued \(queuedItems.count) file(s): \(queuedItems.map(\.fileName).joined(separator: ", "))")
        setStatus("Queued \(queuedItems.count) file(s).")
        startTransferQueueIfNeeded()
    }

    private func uniqueIDsPreservingOrder(_ itemIDs: [MediaItem.ID]) -> [MediaItem.ID] {
        var seen = Set<MediaItem.ID>()
        var result: [MediaItem.ID] = []
        for itemID in itemIDs where !seen.contains(itemID) {
            seen.insert(itemID)
            result.append(itemID)
        }
        return result
    }

    private func startTransferQueueIfNeeded() {
        guard currentTransferTask == nil else {
            return
        }

        currentTransferTask = Task { [weak self] in
            guard let self else { return }
            await self.runBusyTask(isTransfer: true) {
                try await self.processTransferQueue()
            }
            await MainActor.run {
                self.currentTransferTask = nil
            }
        }
    }

    private func processTransferQueue() async throws {
        while let index = transferQueue.firstIndex(where: { $0.status == .pending }) {
            try Task.checkCancellation()
            transferQueue[index].status = .active
            transferQueue[index].message = nil

            let item = transferQueue[index].item
            let entryID = transferQueue[index].id
            appendTransferLog("Started: \(item.fileName)")
            do {
                try await performExclusiveAppTransfer {
                    if item.isGroupedPhoto {
                        try await self.performDownloadGroupedPhotoSequence(item)
                    } else {
                        try await self.performDownloadItem(item)
                    }
                }
                appendTransferLog("Done: \(item.fileName)")
                removeTransferQueueEntry(id: entryID)
            } catch is CancellationError {
                appendTransferLog("Canceled: \(item.fileName)")
                removeTransferQueueEntry(id: entryID)
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                appendTransferLog("Canceled: \(item.fileName)")
                removeTransferQueueEntry(id: entryID)
                throw CancellationError()
            } catch {
                appendTransferLog("Failed: \(item.fileName) / \(error.localizedDescription)")
                removeTransferQueueEntry(id: entryID)
                if isCameraConnectionLoss(error) {
                    throw error
                }
            }
        }
    }

    private func removeTransferQueueEntry(id: UUID) {
        transferQueue.removeAll { $0.id == id }
    }

    private func performExclusiveAppTransfer(_ operation: () async throws -> Void) async throws {
        await TransferGate.shared.acquire()
        do {
            try Task.checkCancellation()
            try await operation()
            await TransferGate.shared.release()
        } catch {
            await TransferGate.shared.release()
            throw error
        }
    }

    func toggleSort(_ key: MediaSortKey) {
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = key == .name
        }
    }

    func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK {
            saveFolder = panel.url
            refreshPartialFiles()
            setStatus("Save folder: \(panel.url?.path(percentEncoded: false) ?? "")")
        }
    }

    func refreshPartialFiles() {
        guard let saveFolder else {
            partialFiles = []
            return
        }

        do {
            partialFiles = try findPartialFiles(in: saveFolder)
        } catch {
            partialFiles = []
            setStatus("Could not check .partial files. \(error.localizedDescription)", isError: true)
        }
    }

    func confirmAndTrashPartialFile(_ file: PartialFile) {
        guard partialFiles.contains(where: { $0.id == file.id }) else {
            refreshPartialFiles()
            setStatus("The .partial file was not found.", isError: true)
            return
        }
        guard !isBusy && !isTransferring else {
            setStatus("Busy. Wait for Done or Cancel before moving .partial files.", isError: true)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Move unfinished file to Trash?"
        alert.informativeText = file.url.path(percentEncoded: false)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        do {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: file.url, resultingItemURL: &trashedURL)
            refreshPartialFiles()
            setStatus("Moved to Trash: \(file.displayName)")
        } catch {
            refreshPartialFiles()
            setStatus("Could not move to Trash. \(error.localizedDescription)", isError: true)
        }
    }

    func autoConnect(showNotFoundError: Bool = true) async {
        autoConnectPaused = false
        pausedUSBURLCandidates = []
        sawUSBDisconnectAfterEject = false
        await runBusyTask {
            setStatus("Connecting...")
            for candidate in connectionCandidates() {
                baseURL = candidate
                do {
                    let response = try await fetchMediaList()
                    try await applyMediaList(response)
                    isConnected = true
                    setStatus("Files loaded. Choose or drag a file to save.")
                    return
                } catch {
                    continue
                }
            }
            isConnected = false
            items = []
            selectedItemID = nil
            selectedItemIDs.removeAll()
            let hasUnsupportedUSBCamera = unsupportedUSBGoProCameraName() != nil
            if showNotFoundError {
                if hasUnsupportedUSBCamera {
                    throw AppError.message("This USB camera is not supported by GPTransfer.")
                }
                throw AppError.message("Camera not found. Check the USB connection, then press Connect.")
            } else {
                if hasUnsupportedUSBCamera {
                    setStatus("This USB camera is not supported by GPTransfer.", isError: true)
                } else {
                    setStatus("No camera. Connect the camera, then press Connect.")
                }
            }
        }
    }

    private func connectionCandidates() -> [String] {
        var candidates = usbCameraURLCandidates()
        candidates.append(baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
        candidates.append(contentsOf: fallbackConnectionCandidates)
        return uniqueNonEmpty(candidates)
    }

    private func usbCameraURLCandidates() -> [String] {
        let candidates = localIPv4Addresses().flatMap { address in
            let parts = address.split(separator: ".")
            guard parts.count == 4,
                  parts[0] == "172",
                  parts[3] != "51" else {
                return [String]()
            }
            let subnet = "\(parts[0]).\(parts[1]).\(parts[2])"
            return ["http://\(subnet).51:8080"]
        }
        return uniqueNonEmpty(candidates)
    }

    private func unsupportedUSBGoProCameraName() -> String? {
        guard usbCameraURLCandidates().isEmpty else {
            return nil
        }
        return connectedUSBGoProProductNames().first
    }

    func testConnection() async {
        autoConnectPaused = false
        pausedUSBURLCandidates = []
        sawUSBDisconnectAfterEject = false
        await runBusyTask {
            setStatus("Connecting...")
            let response = try await fetchMediaList()
            try await applyMediaList(response)
            isConnected = true
            setStatus("Files loaded. Choose or drag a file to save.")
        }
    }

    func loadMediaList() async {
        await runBusyTask {
            let response = try await fetchMediaList()
            try await applyMediaList(response)
            isConnected = true
            setStatus("Files loaded. Choose or drag a file to save.")
        }
    }

    func startDownloadSelectedItem() {
        if !selectedItemIDs.isEmpty {
            let itemIDs = sortedItems.map(\.id).filter { selectedItemIDs.contains($0) }
            enqueueTransfers(itemIDs: itemIDs)
            return
        }

        guard let selectedItemID else {
            setStatus("Choose a file first.", isError: true)
            return
        }

        startDownload(itemID: selectedItemID)
    }

    func startDownload(itemID: MediaItem.ID) {
        guard let item = items.first(where: { $0.id == itemID }) else {
            setStatus("Choose a file first.", isError: true)
            return
        }
        selectedItemID = itemID
        enqueueTransfers(itemIDs: [item.id])
    }

    func handleDroppedMediaItems(_ providers: [NSItemProvider]) -> Bool {
        let mediaProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(MediaDragPayload.type.identifier) }
        if mediaProviders.isEmpty {
            let dragSnapshotIDs = currentInternalDragItemIDs
            guard !dragSnapshotIDs.isEmpty else {
                return false
            }
            currentInternalDragItemIDs = []
            enqueueTransfers(itemIDs: dragSnapshotIDs)
            return true
        }

        let dragSnapshotIDs = currentInternalDragItemIDs
        if dragSnapshotIDs.count > 1 {
            currentInternalDragItemIDs = []
            enqueueTransfers(itemIDs: dragSnapshotIDs)
            return true
        }

        let selectedIDsAtDrop = selectedTransferCandidateIDs()
        if selectedIDsAtDrop.count > 1 {
            currentInternalDragItemIDs = []
            enqueueTransfers(itemIDs: selectedIDsAtDrop)
            return true
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let dragSnapshotIDs = self.currentInternalDragItemIDs
            self.currentInternalDragItemIDs = []
            var itemIDs: [MediaItem.ID] = []
            var hadReadFailure = false
            for provider in mediaProviders {
                let loadedIDs = await loadMediaItemIDs(from: provider)
                if loadedIDs.isEmpty {
                    hadReadFailure = true
                } else {
                    itemIDs.append(contentsOf: expandDroppedIDsIfNeeded(loadedIDs))
                }
            }
            if dragSnapshotIDs.count > 1 {
                itemIDs = dragSnapshotIDs
            }
            if itemIDs.isEmpty {
                if hadReadFailure {
                    self.setStatus("Could not read one or more dropped files.", isError: true)
                } else {
                    self.setStatus("No files to queue.", isError: true)
                }
                return
            }
            if hadReadFailure {
                self.setStatus("Could not read one or more dropped files.", isError: true)
            }
            self.enqueueTransfers(itemIDs: itemIDs)
        }
        return true
    }

    private func expandDroppedIDsIfNeeded(_ droppedIDs: [MediaItem.ID]) -> [MediaItem.ID] {
        let selectedIDs = selectedTransferCandidateIDs()
        guard selectedIDs.count > 1,
              droppedIDs.count == 1,
              let droppedID = droppedIDs.first,
              selectedItemIDs.contains(droppedID) else {
            return droppedIDs
        }
        return selectedIDs
    }

    private func loadMediaItemIDs(from provider: NSItemProvider) async -> [MediaItem.ID] {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: MediaDragPayload.type.identifier) { data, _ in
                guard let data,
                      !data.isEmpty else {
                    continuation.resume(returning: [])
                    return
                }

                if let payload = try? JSONDecoder().decode(DraggedMediaItemIDs.self, from: data) {
                    continuation.resume(returning: payload.itemIDs)
                    return
                }

                guard let itemID = String(data: data, encoding: .utf8), !itemID.isEmpty else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: [itemID])
            }
        }
    }

    private func selectedTransferCandidateIDs() -> [MediaItem.ID] {
        if !selectedItemIDs.isEmpty {
            return sortedItems.map(\.id).filter { selectedItemIDs.contains($0) }
        }
        if let selectedItemID {
            return [selectedItemID]
        }
        return []
    }

    func handleExternalDragEvent(_ event: ExternalDragEvent) {
        switch event {
        case let .started(fileName, expectedSize):
            isBusy = true
            isTransferring = true
            TransferGuard.shared.isTransferring = true
            transferProgress = 0
            transferProgressText = "0 B / \(formatBytes(expectedSize))"
            appendTransferLog("Finder started: \(fileName)")
            setStatus("Preparing: \(fileName)")
        case let .progressed(writtenBytes, expectedSize):
            updateTransferProgress(writtenBytes: writtenBytes, expectedSize: expectedSize)
        case let .finished(fileName, bytes):
            currentExternalDragCancel = nil
            isBusy = false
            isTransferring = false
            TransferGuard.shared.isTransferring = false
            transferProgress = 0
            transferProgressText = ""
            playTransferFinishedSound()
            appendTransferLog("Finder done: \(fileName) / \(formatBytes(bytes))")
            setStatus("Ready for Finder: \(fileName) / \(formatBytes(bytes)). Size OK.")
        case let .failed(fileName, message, isConnectionLost):
            currentExternalDragCancel = nil
            isBusy = false
            isTransferring = false
            TransferGuard.shared.isTransferring = false
            transferProgress = 0
            transferProgressText = ""
            appendTransferLog("Finder failed: \(fileName) / \(message)")
            if isConnectionLost {
                isConnected = false
                setStatus("Camera disconnected. Drag failed: \(fileName). \(message)", isError: true)
                showCameraDisconnectedAlert(message)
            } else {
                setStatus("Drag failed: \(fileName). \(message)", isError: true)
            }
        case let .canceled(fileName):
            currentExternalDragCancel = nil
            isBusy = false
            isTransferring = false
            TransferGuard.shared.isTransferring = false
            transferProgress = 0
            transferProgressText = ""
            appendTransferLog("Finder canceled: \(fileName)")
            setStatus("Drag canceled: \(fileName).")
        }
    }

    func cancelTransfer() {
        if let currentTransferTask {
            currentTransferTask.cancel()
            let pendingEntries = transferQueue.filter { $0.status == .pending }
            for entry in pendingEntries {
                appendTransferLog("Canceled before transfer: \(entry.item.fileName)")
            }
            let pendingIDs = Set(pendingEntries.map(\.id))
            transferQueue.removeAll { pendingIDs.contains($0.id) }
            setStatus("Canceling active transfer and queued items. Do not unplug yet.")
            return
        }

        if let currentExternalDragCancel {
            currentExternalDragCancel()
            setStatus("Canceling Finder drag transfer. Do not unplug yet.")
            return
        }

        setStatus("No transfer to cancel.")
    }

    func prepareSafeDisconnect() {
        guard !isBusy && !isTransferring else {
            setStatus("Busy. Wait for Done or Cancel before unplugging.", isError: true)
            return
        }

        deferredSizeRefreshTask?.cancel()
        deferredSizeRefreshTask = nil
        ThumbnailImageCache.shared.removeAll()
        items = []
        selectedItemID = nil
        selectedItemIDs.removeAll()
        transferQueue.removeAll()
        isConnected = false
        autoConnectPaused = true
        pausedUSBURLCandidates = Set(usbCameraURLCandidates())
        sawUSBDisconnectAfterEject = pausedUSBURLCandidates.isEmpty
        setStatus("Safe to unplug. If the camera appears in Finder, eject it there too.")
    }

    private func performDownloadItem(_ item: MediaItem) async throws {
        guard let saveFolder else {
            throw AppError.message("Choose a save folder first.")
        }

        let source = try mediaDownloadURL(for: item)
        let resolvedDestination = try resolveDestinationForWrite(original: saveFolder.appendingPathComponent(item.fileName))
        let destination = resolvedDestination.url
        let partialDestination = partialURL(for: destination)
        let expectedSize = try await checkedDownloadSize(for: item, source: source)
        try ensureEnoughFreeSpace(in: saveFolder, requiredBytes: expectedSize)
        if FileManager.default.fileExists(atPath: partialDestination.path(percentEncoded: false)) {
            throw AppError.message("A .partial file already exists. To protect data, transfer will not start: \(partialDestination.path(percentEncoded: false))")
        }

        transferProgress = 0
        transferProgressText = "0 B / \(formatBytes(expectedSize))"
        setStatus("Saving: \(item.path)")

        do {
            let downloadResult = try await streamDownload(from: source, to: partialDestination, expectedSize: expectedSize)
            try Task.checkCancellation()
            let actualSize = try fileSize(at: partialDestination)
            try validateDownloadedSize(
                actualSize: actualSize,
                listedSize: expectedSize,
                responseSize: downloadResult.responseExpectedBytes
            )
            if resolvedDestination.replacesExistingFile,
               FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partialDestination, to: destination)
            playTransferFinishedSound()
            setStatus("Done: \(destination.path(percentEncoded: false)) / \(formatBytes(actualSize)). Size OK.")
        } catch is CancellationError {
            removeCanceledPartialFile(partialDestination)
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            removeCanceledPartialFile(partialDestination)
            throw CancellationError()
        } catch {
            setStatus("\(error.localizedDescription) File kept as .partial.", isError: true)
            throw error
        }
    }

    private func checkedDownloadSize(for item: MediaItem, source: URL) async throws -> Int64 {
        if let sizeBytes = item.sizeBytes, sizeBytes > 0 {
            return sizeBytes
        }
        return try await fetchRequiredDownloadSize(from: source)
    }

    private func performDownloadGroupedPhotoSequence(_ item: MediaItem) async throws {
        guard let saveFolder else {
            throw AppError.message("Choose a save folder first.")
        }

        setStatus("Checking grouped photo sequence: \(item.fileName)")
        let source = try mediaDownloadURL(for: item)
        let members = try await groupedPhotoMembers(
            for: item,
            sourceURL: source,
            includeRAW: true
        )
        let skippedRAW = !members.contains { $0.fileName.hasSuffix(".GPR") }
        let totalBytes = members.reduce(Int64(0)) { $0 + $1.expectedSize }

        try ensureEnoughFreeSpace(in: saveFolder, requiredBytes: totalBytes)
        let resolvedDestinations = try members.map { member in
            try resolveDestinationForWrite(original: saveFolder.appendingPathComponent(member.fileName))
        }

        transferProgress = 0
        if let firstMember = members.first {
            transferProgressText = "0 B / \(formatBytes(firstMember.expectedSize))"
        } else {
            transferProgressText = ""
        }
        if skippedRAW {
            appendTransferLog("RAW skipped: \(item.fileName) / JPG only")
            setStatus("RAW unavailable or zero-byte. Saving JPG only: \(item.fileName) (\(members.count) files)")
        } else {
            setStatus("Saving files: \(item.fileName) (\(members.count) files)")
        }

        var completedBytes: Int64 = 0

        for (member, resolvedDestination) in zip(members, resolvedDestinations) {
            try Task.checkCancellation()
            let destination = resolvedDestination.url
            let partialDestination = partialURL(for: destination)

            do {
                transferProgress = 0
                transferProgressText = "0 B / \(formatBytes(member.expectedSize))"
                let downloadResult = try await streamDownload(
                    from: member.sourceURL,
                    to: partialDestination,
                    expectedSize: member.expectedSize
                )
                try Task.checkCancellation()
                let actualSize = try fileSize(at: partialDestination)
                try validateDownloadedSize(
                    actualSize: actualSize,
                    listedSize: member.expectedSize,
                    responseSize: downloadResult.responseExpectedBytes
                )
                if resolvedDestination.replacesExistingFile,
                   FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: partialDestination, to: destination)
                completedBytes += actualSize
                updateTransferProgress(writtenBytes: actualSize, expectedSize: member.expectedSize)
            } catch is CancellationError {
                removeCanceledPartialFile(partialDestination)
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                removeCanceledPartialFile(partialDestination)
                throw CancellationError()
            }
        }

        playTransferFinishedSound()
        if skippedRAW {
            setStatus("Done: \(saveFolder.path(percentEncoded: false)) / JPG only / \(members.count) files / \(formatBytes(completedBytes)). Size OK.")
        } else {
            setStatus("Done: \(saveFolder.path(percentEncoded: false)) / \(members.count) files / \(formatBytes(completedBytes)). Size OK.")
        }
    }

    private func downloadItem(_ item: MediaItem) async {
        guard saveFolder != nil else {
            setStatus("Choose a save folder first.", isError: true)
            return
        }

        await runBusyTask(isTransfer: true) {
            try await performExclusiveAppTransfer {
                try await self.performDownloadItem(item)
            }
        }
    }

    private func downloadGroupedPhotoSequence(_ item: MediaItem) async {
        guard saveFolder != nil else {
            setStatus("Choose a save folder first.", isError: true)
            return
        }

        await runBusyTask(isTransfer: true) {
            try await performExclusiveAppTransfer {
                try await self.performDownloadGroupedPhotoSequence(item)
            }
        }
    }

    private func applyMediaList(_ response: MediaListResponse) async throws {
        deferredSizeRefreshTask?.cancel()
        let expandedList = try expandedMediaItems(from: response)
        setMediaItems(expandedList.items)
        startDeferredCompanionRefresh(
            for: expandedList.items,
            candidates: expandedList.deferredCandidates
        )
    }

    private func setMediaItems(_ loadedItems: [MediaItem]) {
        ThumbnailImageCache.shared.removeAll()
        let previousSelection = selectedItemIDs
        items = loadedItems.sorted { lhs, rhs in
            lhs.path.localizedStandardCompare(rhs.path) == .orderedDescending
        }
        let availableIDs = Set(items.map(\.id))
        let preservedSelection = previousSelection.intersection(availableIDs)
        if !preservedSelection.isEmpty {
            selectedItemIDs = preservedSelection
            selectedItemID = items.last { preservedSelection.contains($0.id) }?.id
        } else {
            selectedItemID = nil
            selectedItemIDs.removeAll()
        }
    }

    private func expandedMediaItems(from response: MediaListResponse) throws -> ExpandedMediaList {
        var loadedItems: [MediaItem] = []
        var knownNamesByDirectory: [String: Set<String>] = [:]
        var deferredCandidates: [CompanionMediaCandidate] = []

        for directory in response.media {
            let apiItems = directory.files.map { file in
                MediaItem(directory: directory.name, entry: file)
            }
            knownNamesByDirectory[directory.name] = Set(apiItems.map(\.fileName))

            for item in apiItems {
                if item.isGroupedPhoto {
                    let expandedItems = try expandedGroupedPhotoItems(for: item)
                    if expandedItems.isEmpty {
                        loadedItems.append(item)
                    } else {
                        loadedItems.append(contentsOf: expandedItems)
                        knownNamesByDirectory[directory.name, default: []].formUnion(expandedItems.map(\.fileName))
                    }
                    let rawFileNames = try groupedPhotoFileNames(for: item, extensionOverride: "GPR")
                    deferredCandidates.append(contentsOf: rawFileNames.map {
                        CompanionMediaCandidate(fileName: $0, baseItem: item, mediaType: "RAW")
                    })
                } else {
                    loadedItems.append(item)
                }
            }
        }

        deferredCandidates.append(contentsOf: loadedItems.flatMap { item in
            audioSidecarCandidates(for: item, knownNames: knownNamesByDirectory[item.directory] ?? [])
        })
        deferredCandidates.append(contentsOf: loadedItems.flatMap { item in
            rawSidecarCandidates(for: item, knownNames: knownNamesByDirectory[item.directory] ?? [])
        })

        return ExpandedMediaList(items: loadedItems, deferredCandidates: uniqueCompanionCandidates(deferredCandidates))
    }

    private func expandedGroupedPhotoItems(for item: MediaItem) throws -> [MediaItem] {
        let jpgFileNames = try groupedPhotoFileNames(for: item, extensionOverride: nil)
        var expandedItems: [MediaItem] = []
        expandedItems.reserveCapacity(jpgFileNames.count)

        for fileName in jpgFileNames {
            expandedItems.append(item.expandedCopy(fileName: fileName, sizeBytes: nil, mediaType: "Photo"))
        }

        return expandedItems
    }

    private func startDeferredCompanionRefresh(
        for loadedItems: [MediaItem],
        candidates deferredCandidates: [CompanionMediaCandidate]
    ) {
        var candidates = loadedItems
            .filter { $0.sizeBytes == nil && $0.mediaType == "Photo" }
            .map { CompanionMediaCandidate(fileName: $0.fileName, baseItem: $0, mediaType: $0.mediaType ?? "Photo") }
        candidates.append(contentsOf: deferredCandidates)
        guard !candidates.isEmpty else {
            return
        }

        deferredSizeRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let prioritizedCandidates = candidates.sorted { lhs, rhs in
                    let lhsTimestamp = lhs.baseItem.createdTimestamp ?? 0
                    let rhsTimestamp = rhs.baseItem.createdTimestamp ?? 0
                    if lhsTimestamp != rhsTimestamp {
                        return lhsTimestamp > rhsTimestamp
                    }
                    return lhs.baseItem.path.localizedStandardCompare(rhs.baseItem.path) == .orderedAscending
                }

                for chunk in prioritizedCandidates.chunked(into: 16) {
                    try Task.checkCancellation()
                    let sizedItems = try await self.existingCompanionItems(
                        candidates: chunk,
                        timeout: 3,
                        maxConcurrent: 4
                    )
                    try Task.checkCancellation()
                    self.applyDeferredItems(from: sizedItems)
                }
            } catch is CancellationError {
            } catch {
            }
        }
    }

    private func applyDeferredItems(from sizedItems: [MediaItem]) {
        guard isConnected && !autoConnectPaused else {
            return
        }

        let sizesByID = Dictionary(uniqueKeysWithValues: sizedItems.compactMap { item in
            item.sizeBytes.map { (item.id, $0) }
        })
        let existingIDs = Set(items.map(\.id))
        let newItems = sizedItems.filter { !existingIDs.contains($0.id) }
        guard !sizesByID.isEmpty || !newItems.isEmpty else {
            return
        }

        items = items.map { item in
            guard item.sizeBytes == nil, let sizeBytes = sizesByID[item.id] else {
                return item
            }
            return item.copy(sizeBytes: sizeBytes)
        }
        items.append(contentsOf: newItems)
    }

    private func audioSidecarCandidates(for item: MediaItem, knownNames: Set<String>) -> [CompanionMediaCandidate] {
        guard item.canHaveAudioSidecar else {
            return []
        }
        let base = (item.fileName as NSString).deletingPathExtension
        let candidates = ["WAV", "M4A", "AAC"].map { "\(base).\($0)" }
        return candidates
            .filter { !knownNames.contains($0) }
            .map { CompanionMediaCandidate(fileName: $0, baseItem: item, mediaType: "Audio") }
    }

    private func rawSidecarCandidates(for item: MediaItem, knownNames: Set<String>) -> [CompanionMediaCandidate] {
        let ext = (item.fileName as NSString).pathExtension.uppercased()
        guard ext == "JPG" || ext == "JPEG" else {
            return []
        }
        guard item.hasRAW else {
            return []
        }
        let base = (item.fileName as NSString).deletingPathExtension
        let candidate = "\(base).GPR"
        guard !knownNames.contains(candidate) else {
            return []
        }
        return [CompanionMediaCandidate(fileName: candidate, baseItem: item, mediaType: "RAW")]
    }

    private func uniqueCompanionCandidates(_ candidates: [CompanionMediaCandidate]) -> [CompanionMediaCandidate] {
        var seen = Set<String>()
        var result: [CompanionMediaCandidate] = []
        result.reserveCapacity(candidates.count)
        for candidate in candidates {
            let key = "\(candidate.baseItem.directory)/\(candidate.fileName)"
            guard seen.insert(key).inserted else {
                continue
            }
            result.append(candidate)
        }
        return result
    }

    private func existingCompanionItems(
        fileNames: [String],
        baseItem: MediaItem,
        mediaType: String,
        timeout: TimeInterval,
        maxConcurrent: Int = 12
    ) async throws -> [MediaItem] {
        let candidates = fileNames.map {
            CompanionMediaCandidate(fileName: $0, baseItem: baseItem, mediaType: mediaType)
        }
        return try await existingCompanionItems(candidates: candidates, timeout: timeout, maxConcurrent: maxConcurrent)
    }

    private func existingCompanionItems(
        candidates: [CompanionMediaCandidate],
        timeout: TimeInterval,
        maxConcurrent: Int = 12
    ) async throws -> [MediaItem] {
        let preparedCandidates = try candidates.map { candidate in
            (
                candidate: candidate,
                sourceURL: try mediaDownloadURL(directory: candidate.baseItem.directory, fileName: candidate.fileName)
            )
        }

        return try await withThrowingTaskGroup(of: MediaItem?.self) { group in
            var nextIndex = 0

            func addCandidate(_ prepared: (candidate: CompanionMediaCandidate, sourceURL: URL)) {
                group.addTask {
                    do {
                        let expectedSize = try await fetchDownloadSize(from: prepared.sourceURL, timeout: timeout)
                        guard expectedSize > 0 else {
                            return nil
                        }
                        return prepared.candidate.baseItem.expandedCopy(
                            fileName: prepared.candidate.fileName,
                            sizeBytes: expectedSize,
                            mediaType: prepared.candidate.mediaType
                        )
                    } catch {
                        return nil
                    }
                }
            }

            let initialCount = min(maxConcurrent, preparedCandidates.count)
            for _ in 0..<initialCount {
                addCandidate(preparedCandidates[nextIndex])
                nextIndex += 1
            }

            var result: [MediaItem] = []
            for try await item in group {
                try Task.checkCancellation()
                if let item {
                    result.append(item)
                }
                if nextIndex < preparedCandidates.count {
                    addCandidate(preparedCandidates[nextIndex])
                    nextIndex += 1
                }
            }
            return result.sorted { lhs, rhs in
                lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
        }
    }

    private func runBusyTask(isTransfer: Bool = false, _ operation: () async throws -> Void) async {
        isBusy = true
        if isTransfer {
            isTransferring = true
            TransferGuard.shared.isTransferring = true
            transferProgress = 0
            transferProgressText = ""
        }
        statusIsError = false
        defer {
            isBusy = false
            if isTransfer {
                isTransferring = false
                TransferGuard.shared.isTransferring = false
                transferProgress = 0
                transferProgressText = ""
                refreshPartialFiles()
            }
        }

        do {
            try await operation()
        } catch is CancellationError {
            setStatus("Canceled. The unfinished file is not marked as done. Safe to unplug.")
        } catch let error as URLError where error.code == .cancelled {
            setStatus("Canceled. The unfinished file is not marked as done. Safe to unplug.")
        } catch {
            if isTransfer && isCameraConnectionLoss(error) {
                isConnected = false
                setStatus("Camera disconnected. \(error.localizedDescription)", isError: true)
                showCameraDisconnectedAlert(error.localizedDescription)
            } else {
                setStatus(error.localizedDescription, isError: true)
            }
        }
    }

    private func showCameraDisconnectedAlert(_ message: String) {
        NSAlert.cameraDisconnectedDuringTransfer(message).runModal()
    }

    private func fetchMediaList() async throws -> MediaListResponse {
        let url = try endpointURL(pathComponents: ["gopro", "media", "list"])
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response)
        return try JSONDecoder().decode(MediaListResponse.self, from: data)
    }

    func mediaDownloadURL(for item: MediaItem) throws -> URL {
        try mediaDownloadURL(directory: item.directory, fileName: item.fileName)
    }

    func mediaDownloadURL(directory: String, fileName: String) throws -> URL {
        try endpointURL(pathComponents: ["videos", "DCIM", directory, fileName])
    }

    func thumbnailURL(for item: MediaItem) -> URL? {
        guard let thumbnailItem = thumbnailSourceItem(for: item) else {
            return nil
        }
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        components.path = "/gopro/media/thumbnail"
        components.queryItems = [
            URLQueryItem(name: "path", value: thumbnailItem.path)
        ]
        return components.url
    }

    func playbackURL(for item: MediaItem) -> URL? {
        guard item.isPlayableVideo else {
            return nil
        }
        return try? mediaDownloadURL(for: item)
    }

    private func thumbnailSourceItem(for item: MediaItem) -> MediaItem? {
        let ext = (item.fileName as NSString).pathExtension.uppercased()
        switch ext {
        case "GPR":
            return sameBaseMediaItem(
                for: item,
                preferredExtensions: ["JPG", "JPEG"]
            )
        case "WAV", "M4A", "AAC":
            return sameBaseMediaItem(
                for: item,
                preferredExtensions: ["MP4", "MOV"]
            )
        default:
            return item
        }
    }

    private func sameBaseMediaItem(
        for item: MediaItem,
        preferredExtensions: [String]
    ) -> MediaItem? {
        let base = (item.fileName as NSString).deletingPathExtension
        return preferredExtensions.compactMap { preferredExtension in
            items.first { candidate in
                candidate.directory == item.directory &&
                    (candidate.fileName as NSString).deletingPathExtension == base &&
                    (candidate.fileName as NSString).pathExtension.uppercased() == preferredExtension
            }
        }.first
    }

    private func endpointURL(pathComponents: [String]) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            throw AppError.message("Could not prepare the camera connection URL.")
        }
        for component in pathComponents {
            url.append(path: component)
        }
        return url
    }

    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AppError.message("Could not read camera response.")
        }
        guard (200...299).contains(http.statusCode) else {
            throw AppError.message("Camera returned HTTP \(http.statusCode).")
        }
    }

    private func streamDownload(
        from source: URL,
        to destination: URL,
        expectedSize: Int64?
    ) async throws -> DownloadResult {
        var request = URLRequest(url: source)
        request.timeoutInterval = 60 * 60 * 6

        let delegate = StreamingDownloadDelegate(
            destination: destination,
            expectedSize: expectedSize,
            progressHandler: { [weak self] writtenBytes, expectedSize in
                Task { @MainActor in
                    self?.updateTransferProgress(
                        writtenBytes: writtenBytes,
                        expectedSize: expectedSize
                    )
                }
            }
        )
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: queue)
        defer {
            session.invalidateAndCancel()
        }

        return try await withTaskCancellationHandler {
            try await delegate.start(request: request, session: session)
        } onCancel: {
            delegate.cancel()
        }
    }

    private func updateTransferProgress(writtenBytes: Int64, expectedSize: Int64?) {
        if let expectedSize, expectedSize > 0 {
            transferProgress = min(Double(writtenBytes) / Double(expectedSize), 1.0)
            let percent = Int(transferProgress * 100)
            transferProgressText = "\(formatBytes(writtenBytes)) / \(formatBytes(expectedSize)) (\(percent)%)"
        } else {
            transferProgress = 0
            transferProgressText = "\(formatBytes(writtenBytes))"
        }
    }

    private func playTransferFinishedSound() {
        NSSound(named: "Submarine")?.play()
    }

    private func uniqueDestinationURL(in folder: URL, fileName: String) -> URL {
        let fileManager = FileManager.default
        let original = folder.appendingPathComponent(fileName)
        if !fileManager.fileExists(atPath: original.path(percentEncoded: false)),
           !fileManager.fileExists(atPath: partialURL(for: original).path(percentEncoded: false)) {
            return original
        }

        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var counter = 2
        while true {
            let candidateName = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            let candidate = folder.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path(percentEncoded: false)),
               !fileManager.fileExists(atPath: partialURL(for: candidate).path(percentEncoded: false)) {
                return candidate
            }
            counter += 1
        }
    }

    private func uniqueDestinationURLs(in folder: URL, fileNames: [String]) -> [URL] {
        var reservedNames = Set<String>()
        return fileNames.map { fileName in
            uniqueDestinationURL(in: folder, fileName: fileName, reservedNames: &reservedNames)
        }
    }

    private func uniqueDestinationURL(in folder: URL, fileName: String, reservedNames: inout Set<String>) -> URL {
        let fileManager = FileManager.default
        let original = folder.appendingPathComponent(fileName)
        if !reservedNames.contains(original.lastPathComponent),
           !fileManager.fileExists(atPath: original.path(percentEncoded: false)),
           !fileManager.fileExists(atPath: partialURL(for: original).path(percentEncoded: false)) {
            reservedNames.insert(original.lastPathComponent)
            return original
        }

        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var counter = 2
        while true {
            let candidateName = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            let candidate = folder.appendingPathComponent(candidateName)
            if !reservedNames.contains(candidate.lastPathComponent),
               !fileManager.fileExists(atPath: candidate.path(percentEncoded: false)),
               !fileManager.fileExists(atPath: partialURL(for: candidate).path(percentEncoded: false)) {
                reservedNames.insert(candidate.lastPathComponent)
                return candidate
            }
            counter += 1
        }
    }

    private func partialURL(for destination: URL) -> URL {
        URL(filePath: destination.path(percentEncoded: false) + ".partial")
    }

    private func removeCanceledPartialFile(_ partialURL: URL) {
        guard FileManager.default.fileExists(atPath: partialURL.path(percentEncoded: false)) else {
            return
        }
        try? FileManager.default.removeItem(at: partialURL)
        refreshPartialFiles()
    }

    private func ensureEnoughFreeSpace(in folder: URL, item: MediaItem) throws {
        guard let requiredBytes = item.sizeBytes else {
            throw AppError.message("File size is unknown. To protect data, transfer will not start.")
        }

        try ensureEnoughFreeSpace(in: folder, requiredBytes: requiredBytes)
    }

    private func ensureEnoughFreeSpace(in folder: URL, requiredBytes: Int64) throws {
        let values = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let availableBytes = values.volumeAvailableCapacityForImportantUsage else {
            throw AppError.message("Could not check free space. To protect data, transfer will not start.")
        }

        guard availableBytes >= requiredBytes else {
            throw AppError.message("Not enough free space. Need: \(formatBytes(requiredBytes)) / Free: \(formatBytes(availableBytes))")
        }
    }

    private func setStatus(_ message: String, isError: Bool = false) {
        status = message
        statusIsError = isError
    }

    private func appendTransferLog(_ message: String) {
        transferLog.append(TransferLogEntry(date: Date(), message: message))
        if transferLog.count > 200 {
            transferLog.removeFirst(transferLog.count - 200)
        }
    }
}

struct MediaListResponse: Decodable {
    let media: [MediaDirectory]

    enum CodingKeys: String, CodingKey {
        case media
    }
}

struct MediaDirectory: Decodable {
    let name: String
    let files: [MediaFileEntry]

    enum CodingKeys: String, CodingKey {
        case name = "d"
        case files = "fs"
    }
}

struct MediaFileEntry: Decodable {
    let name: String
    let size: String?
    let created: String?
    let modified: String?
    let mediaType: String?
    let groupStart: String?
    let groupEnd: String?
    let raw: String?

    enum CodingKeys: String, CodingKey {
        case name = "n"
        case size = "s"
        case created = "cre"
        case modified = "mod"
        case mediaType = "t"
        case groupStart = "b"
        case groupEnd = "l"
        case raw
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        size = container.decodeLossyStringIfPresent(forKey: .size)
        created = container.decodeLossyStringIfPresent(forKey: .created)
        modified = container.decodeLossyStringIfPresent(forKey: .modified)
        mediaType = container.decodeLossyStringIfPresent(forKey: .mediaType)
        groupStart = container.decodeLossyStringIfPresent(forKey: .groupStart)
        groupEnd = container.decodeLossyStringIfPresent(forKey: .groupEnd)
        raw = container.decodeLossyStringIfPresent(forKey: .raw)
    }
}

extension KeyedDecodingContainer {
    func decodeLossyStringIfPresent(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value ? "1" : "0"
        }
        return nil
    }
}

struct MediaItem: Identifiable, Hashable, Sendable {
    let directory: String
    let fileName: String
    let sizeBytes: Int64?
    let createdTimestamp: Int64?
    let mediaType: String?
    let groupStart: String?
    let groupEnd: String?
    let raw: String?

    var id: String { path }
    var path: String { "\(directory)/\(fileName)" }
    var isOver4GiB: Bool { (sizeBytes ?? 0) > 4 * 1024 * 1024 * 1024 }
    var canHaveAudioSidecar: Bool {
        let ext = (fileName as NSString).pathExtension.uppercased()
        return ext == "MP4" || ext == "MOV"
    }
    var isPlayableVideo: Bool {
        let ext = (fileName as NSString).pathExtension.uppercased()
        return ext == "MP4" || ext == "MOV"
    }
    var isGroupedPhoto: Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard ext == "jpg" || ext == "jpeg" else {
            return false
        }
        guard let groupStart, let groupEnd else {
            return false
        }
        return groupStart != groupEnd
    }
    var hasRAW: Bool {
        guard let raw else { return false }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "1" || normalized == "true" || normalized == "yes"
    }
    var kindDescription: String {
        let ext = (fileName as NSString).pathExtension.uppercased()
        return ext.isEmpty ? (mediaType ?? "Unknown") : ext
    }
    var groupedPhotoUnsupportedMessage: String {
        if let groupStart, let groupEnd {
            return "Grouped photo sequence is not supported yet. To protect data, this app will not save only one file from \(fileName) (\(groupStart)-\(groupEnd))."
        }
        return "Grouped photo sequence is not supported yet. To protect data, this app will not save only part of it."
    }
    var sizeDescription: String {
        guard let sizeBytes else { return "—" }
        return formatBytes(sizeBytes)
    }
    var createdDescription: String {
        guard let createdTimestamp else { return "Unknown" }
        return mediaDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(createdTimestamp)))
    }

    init(directory: String, entry: MediaFileEntry) {
        self.directory = directory
        fileName = entry.name
        sizeBytes = entry.size.flatMap(Int64.init)
        createdTimestamp = entry.created.flatMap(Int64.init)
        mediaType = entry.mediaType
        groupStart = entry.groupStart
        groupEnd = entry.groupEnd
        raw = entry.raw
    }

    init(
        directory: String,
        fileName: String,
        sizeBytes: Int64?,
        createdTimestamp: Int64?,
        mediaType: String?,
        groupStart: String? = nil,
        groupEnd: String? = nil,
        raw: String? = nil
    ) {
        self.directory = directory
        self.fileName = fileName
        self.sizeBytes = sizeBytes
        self.createdTimestamp = createdTimestamp
        self.mediaType = mediaType
        self.groupStart = groupStart
        self.groupEnd = groupEnd
        self.raw = raw
    }

    func expandedCopy(fileName: String, sizeBytes: Int64?, mediaType: String?) -> MediaItem {
        MediaItem(
            directory: directory,
            fileName: fileName,
            sizeBytes: sizeBytes,
            createdTimestamp: createdTimestamp,
            mediaType: mediaType,
            raw: mediaType == "RAW" ? "1" : nil
        )
    }

    func copy(sizeBytes: Int64?) -> MediaItem {
        MediaItem(
            directory: directory,
            fileName: fileName,
            sizeBytes: sizeBytes,
            createdTimestamp: createdTimestamp,
            mediaType: mediaType,
            groupStart: groupStart,
            groupEnd: groupEnd,
            raw: raw
        )
    }
}

func groupedPhotoFolderName(for item: MediaItem) -> String {
    let base = (item.fileName as NSString).deletingPathExtension
    if let groupStart = item.groupStart, let groupEnd = item.groupEnd {
        return "\(base)_\(groupStart)-\(groupEnd)"
    }
    return "\(base)_grouped"
}

func groupedPhotoMembers(for item: MediaItem, sourceURL: URL, includeRAW: Bool) async throws -> [GroupedPhotoMember] {
    let folderURL = sourceURL.deletingLastPathComponent()
    return try await groupedPhotoMembers(for: item, includeRAW: includeRAW) { fileName in
        folderURL.appendingPathComponent(fileName)
    }
}

func groupedPhotoMembers(
    for item: MediaItem,
    includeRAW: Bool,
    makeSourceURL: @Sendable (String) throws -> URL
) async throws -> [GroupedPhotoMember] {
    let jpgFileNames = try groupedPhotoFileNames(for: item, extensionOverride: nil)
    var members: [GroupedPhotoMember] = []
    members.reserveCapacity(jpgFileNames.count)

    for fileName in jpgFileNames {
        try Task.checkCancellation()
        let sourceURL = try makeSourceURL(fileName)
        let expectedSize = try await fetchRequiredDownloadSize(from: sourceURL)
        members.append(GroupedPhotoMember(fileName: fileName, sourceURL: sourceURL, expectedSize: expectedSize))
    }

    guard includeRAW else {
        return members
    }

    let rawFileNames = try groupedPhotoFileNames(for: item, extensionOverride: "GPR")
    members.reserveCapacity(jpgFileNames.count + rawFileNames.count)

    var rawMembers: [GroupedPhotoMember] = []
    rawMembers.reserveCapacity(rawFileNames.count)
    for fileName in rawFileNames {
        try Task.checkCancellation()
        let sourceURL = try makeSourceURL(fileName)
        do {
            let expectedSize = try await fetchDownloadSize(from: sourceURL)
            guard expectedSize > 0 else {
                return members
            }
            rawMembers.append(GroupedPhotoMember(fileName: fileName, sourceURL: sourceURL, expectedSize: expectedSize))
        } catch {
            return members
        }
    }

    members.append(contentsOf: rawMembers)
    return members
}

func groupedPhotoFileNames(for item: MediaItem, extensionOverride: String?) throws -> [String] {
    guard let groupStart = item.groupStart,
          let groupEnd = item.groupEnd,
          let startNumber = Int(groupStart),
          let endNumber = Int(groupEnd),
          startNumber <= endNumber else {
        throw AppError.message("Could not read grouped photo range. To protect data, transfer will not start.")
    }

    let count = endNumber - startNumber + 1
    guard count <= 500 else {
        throw AppError.message("Grouped photo sequence is too large to prepare safely. To protect data, transfer will not start.")
    }

    let base = (item.fileName as NSString).deletingPathExtension
    let ext = extensionOverride ?? (item.fileName as NSString).pathExtension
    guard let numberRange = base.range(of: #"\d+$"#, options: .regularExpression) else {
        throw AppError.message("Could not build grouped photo file names. To protect data, transfer will not start.")
    }

    let prefix = String(base[..<numberRange.lowerBound])
    let width = String(base[numberRange]).count
    return (startNumber...endNumber).map { number in
        let numberedName = prefix + String(format: "%0\(width)d", number)
        return ext.isEmpty ? numberedName : "\(numberedName).\(ext)"
    }
}

func fetchRequiredDownloadSize(from url: URL) async throws -> Int64 {
    let expectedSize = try await fetchDownloadSize(from: url)
    guard expectedSize > 0 else {
        throw AppError.message("Could not check file size before transfer. To protect data, transfer will not start.")
    }
    return expectedSize
}

func fetchDownloadSize(from url: URL, timeout: TimeInterval = 30) async throws -> Int64 {
    var request = URLRequest(url: url)
    request.httpMethod = "HEAD"
    request.timeoutInterval = timeout
    let (_, response) = try await URLSession.shared.data(for: request)
    try validateDownloadHTTPResponse(response)
    let expectedSize = response.expectedContentLength
    guard expectedSize >= 0 else {
        throw AppError.message("Could not check file size before transfer. To protect data, transfer will not start.")
    }
    return expectedSize
}

func validateDownloadHTTPResponse(_ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else {
        throw AppError.message("Could not read camera response.")
    }
    guard (200...299).contains(http.statusCode) else {
        throw AppError.message("Camera returned HTTP \(http.statusCode).")
    }
}

enum AppError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(message):
            return message
        }
    }
}

final class StreamingDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let expectedSize: Int64?
    private let progressHandler: @Sendable (Int64, Int64?) -> Void
    private let lock = NSLock()

    private var fileHandle: FileHandle?
    private var writtenBytes: Int64 = 0
    private var responseExpectedBytes: Int64?
    private var continuation: CheckedContinuation<DownloadResult, Error>?
    private var task: URLSessionDataTask?
    private var isFinished = false

    init(
        destination: URL,
        expectedSize: Int64?,
        progressHandler: @escaping @Sendable (Int64, Int64?) -> Void
    ) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.progressHandler = progressHandler
    }

    func start(request: URLRequest, session: URLSession) async throws -> DownloadResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            let task = session.dataTask(with: request)
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        let task = task
        lock.unlock()
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(AppError.message("HTTPレスポンスを確認できませんでした。")))
            completionHandler(.cancel)
            return
        }

        guard (200...299).contains(http.statusCode) else {
            finish(.failure(AppError.message("GoProからHTTP \(http.statusCode)が返りました。")))
            completionHandler(.cancel)
            return
        }

        do {
            FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            let responseExpectedBytes = response.expectedContentLength > 0 ? response.expectedContentLength : nil
            lock.lock()
            self.responseExpectedBytes = responseExpectedBytes
            writtenBytes = 0
            fileHandle = handle
            lock.unlock()
            completionHandler(.allow)
        } catch {
            finish(.failure(error))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !isFinished, let fileHandle else {
            lock.unlock()
            return
        }

        do {
            try fileHandle.write(contentsOf: data)
            writtenBytes += Int64(data.count)
            let currentWrittenBytes = writtenBytes
            let expectedSize = expectedSize
            lock.unlock()
            progressHandler(currentWrittenBytes, expectedSize)
        } catch {
            lock.unlock()
            finish(.failure(error))
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as? URLError)?.code == .cancelled {
                finish(.failure(CancellationError()))
            } else {
                finish(.failure(error))
            }
            return
        }

        lock.lock()
        let finalWrittenBytes = writtenBytes
        let responseExpectedBytes = responseExpectedBytes
        lock.unlock()
        finish(.success(DownloadResult(writtenBytes: finalWrittenBytes, responseExpectedBytes: responseExpectedBytes)))
    }

    private func finish(_ result: Result<DownloadResult, Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        let handle = fileHandle
        fileHandle = nil
        lock.unlock()

        try? handle?.synchronize()
        try? handle?.close()

        switch result {
        case let .success(bytes):
            continuation?.resume(returning: bytes)
        case let .failure(error):
            continuation?.resume(throwing: error)
        }
    }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func fileSize(at url: URL) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
    guard let size = attributes[.size] as? NSNumber else {
        throw AppError.message("Could not check saved file size.")
    }
    return size.int64Value
}

func externalPartialURL(for destination: URL) -> URL {
    URL(filePath: destination.path(percentEncoded: false) + ".partial")
}

func removePartialFileAfterUserCancel(_ partialURL: URL) {
    guard FileManager.default.fileExists(atPath: partialURL.path(percentEncoded: false)) else {
        return
    }
    try? FileManager.default.removeItem(at: partialURL)
}

func ensureExternalFreeSpace(in folder: URL, requiredBytes: Int64) throws {
    let values = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    guard let availableBytes = values.volumeAvailableCapacityForImportantUsage else {
        throw AppError.message("Could not check free space. To protect data, transfer will not start.")
    }

    guard availableBytes >= requiredBytes else {
        throw AppError.message("Not enough free space. Need: \(formatBytes(requiredBytes)) / Free: \(formatBytes(availableBytes))")
    }
}

func findPartialFiles(in folder: URL) throws -> [PartialFile] {
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .isRegularFileKey]
    let urls = try FileManager.default.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: Array(keys),
        options: []
    )

    return try urls
        .filter { $0.lastPathComponent.hasSuffix(".partial") }
        .map { url in
            let values = try url.resourceValues(forKeys: keys)
            let isDirectory = values.isDirectory ?? false
            let sizeBytes = isDirectory ? folderSize(at: url) : values.fileSize.map(Int64.init)
            return PartialFile(url: url, isDirectory: isDirectory, sizeBytes: sizeBytes)
        }
        .sorted { lhs, rhs in
            lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
}

func folderSize(at folder: URL) -> Int64? {
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
    guard let enumerator = FileManager.default.enumerator(
        at: folder,
        includingPropertiesForKeys: keys,
        options: [.skipsPackageDescendants]
    ) else {
        return nil
    }

    var total: Int64 = 0
    for case let url as URL in enumerator {
        guard let values = try? url.resourceValues(forKeys: Set(keys)),
              values.isRegularFile == true,
              let fileSize = values.fileSize else {
            continue
        }
        total += Int64(fileSize)
    }
    return total
}

func validateDownloadedSize(actualSize: Int64, listedSize: Int64?, responseSize: Int64?) throws {
    if let listedSize, actualSize == listedSize {
        return
    }

    if let responseSize, actualSize == responseSize {
        return
    }

    let listedDescription = listedSize.map(formatBytes) ?? "Unknown"
    let responseDescription = responseSize.map(formatBytes) ?? "Unknown"
    throw AppError.message(
        "Size mismatch. Camera list: \(listedDescription) / HTTP: \(responseDescription) / Mac: \(formatBytes(actualSize))."
    )
}

func isCameraConnectionLoss(_ error: Error) -> Bool {
    let nsError = error as NSError
    guard nsError.domain == NSURLErrorDomain else {
        return false
    }

    let code = URLError.Code(rawValue: nsError.code)
    switch code {
    case .networkConnectionLost,
         .notConnectedToInternet,
         .cannotConnectToHost,
         .cannotFindHost,
         .dnsLookupFailed,
         .timedOut:
        return true
    default:
        return false
    }
}

func localIPv4Addresses() -> [String] {
    var addresses: [String] = []
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
        return addresses
    }
    defer {
        freeifaddrs(interfaces)
    }

    for pointer in sequence(first: firstInterface, next: { $0.pointee.ifa_next }) {
        let interface = pointer.pointee
        let flags = Int32(interface.ifa_flags)
        guard flags & IFF_UP != 0,
              flags & IFF_LOOPBACK == 0,
              let address = interface.ifa_addr,
              address.pointee.sa_family == UInt8(AF_INET) else {
            continue
        }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            address,
            socklen_t(address.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        if result == 0 {
            host.withUnsafeBufferPointer { buffer in
                if let baseAddress = buffer.baseAddress {
                    addresses.append(String(cString: baseAddress))
                }
            }
        }
    }

    return addresses
}

func connectedUSBGoProProductNames() -> [String] {
    guard let matchingDictionary = IOServiceMatching("IOUSBHostDevice") else {
        return []
    }

    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary, &iterator) == KERN_SUCCESS else {
        return []
    }
    defer {
        IOObjectRelease(iterator)
    }

    var productNames: [String] = []
    while case let service = IOIteratorNext(iterator), service != 0 {
        defer {
            IOObjectRelease(service)
        }

        guard usbRegistryIntProperty("idVendor", service: service) == 0x2672 else {
            continue
        }

        let productName = usbRegistryStringProperty("USB Product Name", service: service)
            ?? usbRegistryStringProperty("kUSBProductString", service: service)
            ?? "GoPro USB camera"
        if !productNames.contains(productName) {
            productNames.append(productName)
        }
    }

    return productNames
}

private func usbRegistryIntProperty(_ key: String, service: io_object_t) -> Int? {
    guard let property = IORegistryEntryCreateCFProperty(
        service,
        key as CFString,
        kCFAllocatorDefault,
        0
    )?.takeRetainedValue() as? NSNumber else {
        return nil
    }
    return property.intValue
}

private func usbRegistryStringProperty(_ key: String, service: io_object_t) -> String? {
    IORegistryEntryCreateCFProperty(
        service,
        key as CFString,
        kCFAllocatorDefault,
        0
    )?.takeRetainedValue() as? String
}

func uniqueNonEmpty(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for value in values {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !seen.contains(trimmed) else {
            continue
        }
        seen.insert(trimmed)
        result.append(trimmed)
    }
    return result
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else {
            return [self]
        }
        return stride(from: 0, to: count, by: size).map { startIndex in
            Array(self[startIndex..<Swift.min(startIndex + size, count)])
        }
    }
}

func compareOptional<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
    switch (lhs, rhs) {
    case let (lhs?, rhs?):
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    case (nil, nil):
        return .orderedSame
    case (nil, _?):
        return .orderedAscending
    case (_?, nil):
        return .orderedDescending
    }
}

let mediaDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter
}()

extension String {
    var pathExtensionLabel: String {
        let ext = (self as NSString).pathExtension
        return ext.isEmpty ? "File" : ext.uppercased()
    }
}
