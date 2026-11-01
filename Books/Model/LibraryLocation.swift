import Foundation

/// Where the library folder lives: the app's iCloud container (`iCloud Drive › Books`, shown with the
/// app icon), or `~/Documents/Books` without iCloud Drive or the iCloud entitlement.
enum LibraryLocation {
    static let containerID = "iCloud.com.zyu.books"

    static var localRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Books", isDirectory: true)
    }

    /// The container's `Documents` folder, or nil when iCloud is unavailable. Blocks while iCloud sets up
    /// the container; call off the main thread.
    static func iCloudRoot() -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: containerID)?
            .appendingPathComponent("Documents", isDirectory: true)
    }
}
