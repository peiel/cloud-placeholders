import CloudPlaceholderDomain
import CloudPlaceholderPersistence
import CloudPlaceholderSync
import Foundation

@main
struct CloudSyncDemo {
    static func main() async throws {
        let fileManager = FileManager.default
        let baseDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent(".demo-state", isDirectory: true)
        let databaseURL = baseDirectory.appendingPathComponent("client.sqlite")
        let cacheDirectory = baseDirectory.appendingPathComponent("cache", isDirectory: true)
        let uploadDirectory = baseDirectory.appendingPathComponent("local", isDirectory: true)

        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: uploadDirectory, withIntermediateDirectories: true)

        let store = try SQLiteMetadataStore(databaseURL: databaseURL)
        try seedRootIfNeeded(store: store)

        guard
            let baseURLString = ProcessInfo.processInfo.environment["MOCK_SERVER_URL"],
            let baseURL = URL(string: baseURLString)
        else {
            print("已初始化本地客户端状态库：\(databaseURL.path)")
            print("设置环境变量 MOCK_SERVER_URL 后可执行完整同步 demo，例如：")
            print("MOCK_SERVER_URL=http://127.0.0.1:8787 swift run cloudsync-demo")
            return
        }

        let remote = HTTPRemoteAPIClient(baseURL: baseURL)
        let engine = SyncEngine(domainID: "primary", store: store, remote: remote)

        let policy = try await engine.register(
            device: DeviceRegistration(
                tenantID: "tenant-demo",
                userID: "peiel",
                deviceID: Host.current().localizedName ?? UUID().uuidString,
                hostName: Host.current().localizedName ?? "demo-mac",
                deploymentMode: .managedCloud
            )
        )
        print("设备注册成功，缓存上限：\(policy.offlineCacheLimitBytes) bytes")

        try await engine.syncDown()
        let rootChildren = try store.children(of: "root")
        print("首轮同步完成，root 子项数量：\(rootChildren.count)")

        let sampleFile = uploadDirectory.appendingPathComponent("hello.txt")
        if !fileManager.fileExists(atPath: sampleFile.path) {
            try "hello from cloud placeholder demo\n".write(to: sampleFile, atomically: true, encoding: .utf8)
        }
        _ = try engine.stageLocalFile(itemID: "demo-hello", parentID: "root", fileURL: sampleFile)
        try await engine.flushPendingOperations()
        print("本地文件已上传：\(sampleFile.lastPathComponent)")
    }

    private static func seedRootIfNeeded(store: SQLiteMetadataStore) throws {
        guard try store.item(id: "root") == nil else {
            return
        }
        try store.upsert(
            item: SyncItem(
                id: "root",
                parentID: nil,
                name: "Enterprise Cloud Drive",
                kind: .directory,
                state: .hydrated,
                hydrated: true
            )
        )
    }
}
