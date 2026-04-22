import FileProvider
import Foundation

struct FileProviderDomainInstaller {
    private let domainIdentifier = NSFileProviderDomainIdentifier("primary")
    private let displayName = "Enterprise Cloud Drive"

    func installPrimaryDomain() async throws {
        let domain = NSFileProviderDomain(identifier: domainIdentifier, displayName: displayName)
        let existingDomainIdentifiers = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: domains.map(\.identifier.rawValue))
                }
            }
        }
        if existingDomainIdentifiers.contains(domainIdentifier.rawValue) {
            return
        }
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
