import CloudPlaceholderDomain
import CloudPlaceholderSync
import FileProvider
import SwiftUI

@main
struct EnterpriseCloudDriveApp: App {
    @StateObject private var model = CloudDriveAppModel()

    var body: some Scene {
        MenuBarExtra("Enterprise Cloud Drive", systemImage: "externaldrive.connected.to.line.below") {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.domainDisplayName)
                    .font(.headline)
                Text(model.statusMessage)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                if !model.lastSyncStatus.isEmpty {
                    Text(model.lastSyncStatus)
                        .foregroundStyle(.secondary)
                        .font(.caption2)
                }
                Divider()
                Button("注册 File Provider Domain") {
                    model.registerDomain()
                }
                if model.backendKind == .mockServer {
                    Button("打开 Mock Admin Console") {
                        model.openAdminConsole()
                    }
                } else {
                    Button("选择本地目录") {
                        model.chooseLocalDirectory()
                    }
                }
                Button("打开共享数据目录") {
                    model.openSharedDataDirectory()
                }
                Button("立即同步") {
                    model.forceSync()
                }
                SettingsLink {
                    Text("Settings…")
                }
                .keyboardShortcut(",", modifiers: .command)
                Divider()
                Button("退出") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(12)
            .frame(width: 320)
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

@MainActor
final class CloudDriveAppModel: ObservableObject {
    @Published var statusMessage = "尚未注册 File Provider domain"
    @Published var lastSyncStatus = ""
    @Published var backendKind: BackendKind
    @Published var mockServerURL: String
    @Published var sourceDisplayName: String
    @Published var sourceDirectoryPath: String
    @Published var bookmarkStatus = "未配置本地目录"
    @Published var domainDisplayName: String

    private let installer = FileProviderDomainInstaller()
    private let configurationStore = CloudDriveSharedConfigurationStore()
    private var runtimeContext: CloudDriveRuntimeContext?
    private var bootstrapCoordinator: SyncBootstrapCoordinator?
    private var watcher: SourceDirectoryWatcher?
    private var debounceTask: Task<Void, Never>?

    init() {
        let configuration = configurationStore.loadBackendConfiguration()
        self.backendKind = configuration.backendKind
        self.mockServerURL = configuration.mockServerURL ?? CloudDriveSharedConfigurationStore.defaultMockServerURL
        self.sourceDisplayName = configuration.sourceDisplayName ?? ""
        self.sourceDirectoryPath = ""
        self.domainDisplayName = configuration.domainDisplayName
        reloadRuntimeAndWatcher()
        Task { await performInitialSyncIfNeeded() }
    }

    func registerDomain() {
        print("[App] registerDomain() called")
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.persistConfiguration()
                print("[App] persistConfiguration done, calling installPrimaryDomain...")
                try await self.installer.installPrimaryDomain()
                print("[App] installPrimaryDomain succeeded")
                self.statusMessage = "已注册 \(self.domainDisplayName) domain"
                self.forceSync(reason: "domain 注册后同步")
            } catch {
                print("[App] registerDomain error: \(error)")
                self.statusMessage = "注册失败：\(error.localizedDescription)"
            }
        }
    }

    func openAdminConsole() {
        persistConfiguration()
        guard let url = URL(string: "\(mockServerURL)/admin") else {
            statusMessage = "Mock server URL 无效"
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openSharedDataDirectory() {
        let url = configurationStore.sharedContainerRoot()
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        } catch {
            statusMessage = "打开共享目录失败：\(error.localizedDescription)"
        }
    }

    func chooseLocalDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            sourceDisplayName = url.lastPathComponent
            sourceDirectoryPath = url.path
            domainDisplayName = url.lastPathComponent
            bookmarkStatus = "已授权：\(url.path)"
            statusMessage = "已选择本地目录 \(url.lastPathComponent)"
            persistConfiguration(sourceBookmarkData: bookmark)
            reloadRuntimeAndWatcher()
            Task { forceSync(reason: "本地目录更新") }
        } catch {
            statusMessage = "创建目录 bookmark 失败：\(error.localizedDescription)"
        }
    }

    func persistConfiguration(sourceBookmarkData: Data? = nil) {
        let configuration = BackendConfiguration(
            backendKind: backendKind,
            mockServerURL: mockServerURL,
            sourceBookmarkData: sourceBookmarkData ?? configurationStore.loadBackendConfiguration().sourceBookmarkData,
            sourceDisplayName: sourceDisplayName.isEmpty ? nil : sourceDisplayName,
            domainDisplayName: domainDisplayName.isEmpty
                ? CloudDriveSharedConfigurationStore.defaultDomainDisplayName
                : domainDisplayName
        )
        configurationStore.saveBackendConfiguration(configuration)
    }

    func updateBackendSelection() {
        persistConfiguration()
        reloadRuntimeAndWatcher()
        Task { await performInitialSyncIfNeeded() }
    }

    func performInitialSyncIfNeeded() async {
        guard let bootstrapCoordinator else {
            return
        }
        do {
            try await bootstrapCoordinator.ensureInitialSync()
            await FileProviderDomainSignaler.signal(
                domainIdentifier: "primary",
                itemIdentifiers: [CloudDriveRuntime.rootItemID]
            )
            lastSyncStatus = "首轮同步完成"
        } catch {
            lastSyncStatus = "首轮同步失败：\(error.localizedDescription)"
            statusMessage = lastSyncStatus
        }
    }

    func forceSync(reason: String = "手动同步") {
        guard let bootstrapCoordinator else {
            statusMessage = "同步运行时尚未就绪"
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.bootstrapCoordinator?.forceSync()
                await FileProviderDomainSignaler.signal(
                    domainIdentifier: "primary",
                    itemIdentifiers: [CloudDriveRuntime.rootItemID]
                )
                self.lastSyncStatus = "\(reason)：\(DateFormatter.syncStatus.string(from: Date()))"
            } catch {
                self.lastSyncStatus = "\(reason)失败：\(error.localizedDescription)"
                self.statusMessage = self.lastSyncStatus
                self.refreshBookmarkStatus()
            }
        }
    }

    private func reloadRuntimeAndWatcher() {
        persistConfiguration()
        do {
            let runtime = try CloudDriveRuntime.bootstrap(domainIdentifier: "primary")
            runtimeContext = runtime
            bootstrapCoordinator = SyncBootstrapCoordinator(
                domainID: "primary",
                store: runtime.store,
                syncEngine: runtime.syncEngine
            )
            statusMessage = "运行时已就绪"
        } catch {
            runtimeContext = nil
            bootstrapCoordinator = nil
            statusMessage = "初始化运行时失败：\(error.localizedDescription)"
        }
        refreshBookmarkStatus()
        restartWatcherIfNeeded()
    }

    private func refreshBookmarkStatus() {
        let configuration = configurationStore.loadBackendConfiguration()
        domainDisplayName = configuration.domainDisplayName
        sourceDisplayName = configuration.sourceDisplayName ?? ""
        guard configuration.backendKind == .localDirectory else {
            sourceDirectoryPath = ""
            bookmarkStatus = "当前使用 Mock Server"
            return
        }
        guard let bookmarkData = configuration.sourceBookmarkData else {
            sourceDirectoryPath = ""
            bookmarkStatus = "尚未选择本地目录"
            return
        }
        do {
            let access = try SecurityScopedResourceAccess(bookmarkData: bookmarkData)
            sourceDirectoryPath = access.url.path
            bookmarkStatus = "已授权：\(access.url.path)"
        } catch {
            sourceDirectoryPath = ""
            bookmarkStatus = "目录不可用：\(error.localizedDescription)"
        }
    }

    private func restartWatcherIfNeeded() {
        watcher?.invalidate()
        watcher = nil
        let configuration = configurationStore.loadBackendConfiguration()
        guard configuration.backendKind == .localDirectory, let bookmarkData = configuration.sourceBookmarkData else {
            return
        }
        do {
            watcher = try SourceDirectoryWatcher(bookmarkData: bookmarkData) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.scheduleDebouncedSync()
                }
            }
            watcher?.start()
        } catch {
            statusMessage = "启动目录监听失败：\(error.localizedDescription)"
        }
    }

    private func scheduleDebouncedSync() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.forceSync(reason: "检测到源目录变化")
        }
    }

    var sharedContainerPath: String {
        configurationStore.sharedContainerRoot().path
    }
}

struct SettingsView: View {
    @ObservedObject var model: CloudDriveAppModel

    var body: some View {
        Form {
            Picker("Backend", selection: $model.backendKind) {
                Text("Mock Server").tag(BackendKind.mockServer)
                Text("Local Directory").tag(BackendKind.localDirectory)
            }
            .onChange(of: model.backendKind) { _, _ in
                model.updateBackendSelection()
            }

            if model.backendKind == .mockServer {
                TextField("Mock Server URL", text: $model.mockServerURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        model.persistConfiguration()
                    }
                Text("用于开发阶段接本地 mock server。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text(model.sourceDirectoryPath.isEmpty ? "未选择目录" : model.sourceDirectoryPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("选择目录") {
                        model.chooseLocalDirectory()
                    }
                }
                Text(model.bookmarkStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("共享数据目录：\(model.sharedContainerPath)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if !model.lastSyncStatus.isEmpty {
                Text(model.lastSyncStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button("保存配置") {
                model.persistConfiguration()
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

private extension DateFormatter {
    static let syncStatus: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}
