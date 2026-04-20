import FileProvider
import SwiftUI

private enum CloudDriveSharedConfiguration {
    static let appGroupID = "group.com.peiel.enterprisecloud.drive"
    static let mockServerURLKey = "MockServerURL"
    static let defaultMockServerURL = "http://127.0.0.1:8787"

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    static func sharedContainerRoot() -> URL {
        let fileManager = FileManager.default
        let base = (
            fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        )
        return base.appendingPathComponent("EnterpriseCloudDriveShared", isDirectory: true)
    }
}

@main
struct EnterpriseCloudDriveApp: App {
    @StateObject private var model = CloudDriveAppModel()

    var body: some Scene {
        MenuBarExtra("Enterprise Cloud Drive", systemImage: "externaldrive.connected.to.line.below") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Enterprise Cloud Drive")
                    .font(.headline)
                Text(model.statusMessage)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Divider()
                Button("注册 File Provider Domain") {
                    Task { await model.registerDomain() }
                }
                Button("打开 Mock Admin Console") {
                    model.openAdminConsole()
                }
                Button("打开共享数据目录") {
                    model.openSharedDataDirectory()
                }
                Button("退出") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(12)
            .frame(width: 280)
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

@MainActor
final class CloudDriveAppModel: ObservableObject {
    @Published var statusMessage = "尚未注册 File Provider domain"
    @Published var mockServerURL: String

    private let installer = FileProviderDomainInstaller()

    init() {
        self.mockServerURL = CloudDriveSharedConfiguration.sharedDefaults.string(
            forKey: CloudDriveSharedConfiguration.mockServerURLKey
        ) ?? CloudDriveSharedConfiguration.defaultMockServerURL
    }

    func registerDomain() async {
        do {
            persistConfiguration()
            try await installer.installPrimaryDomain()
            statusMessage = "已注册 Enterprise Cloud Drive domain"
        } catch {
            statusMessage = "注册失败：\(error.localizedDescription)"
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
        let url = CloudDriveSharedConfiguration.sharedContainerRoot()
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        } catch {
            statusMessage = "打开共享目录失败：\(error.localizedDescription)"
        }
    }

    func persistConfiguration() {
        CloudDriveSharedConfiguration.sharedDefaults.set(
            mockServerURL,
            forKey: CloudDriveSharedConfiguration.mockServerURLKey
        )
    }
}

struct SettingsView: View {
    @ObservedObject var model: CloudDriveAppModel

    var body: some View {
        Form {
            TextField("Mock Server URL", text: $model.mockServerURL)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    model.persistConfiguration()
                }
            Button("保存配置") {
                model.persistConfiguration()
            }
            Text("此设置用于开发阶段让 App 和 File Provider Extension 指向本地 mock server。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("共享数据目录：\(CloudDriveSharedConfiguration.sharedContainerRoot().path)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 460)
    }
}
