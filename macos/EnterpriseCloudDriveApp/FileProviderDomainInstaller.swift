import FileProvider
import Foundation

struct FileProviderDomainInstaller {
    private let domainIdentifier = NSFileProviderDomainIdentifier("primary")
    private let displayName = "Enterprise Cloud Drive"

    func installPrimaryDomain() async throws {
        let domain = NSFileProviderDomain(identifier: domainIdentifier, displayName: displayName)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSFileProviderManager.add(domain) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}
