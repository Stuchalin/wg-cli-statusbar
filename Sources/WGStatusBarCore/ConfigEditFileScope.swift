import Darwin
import Foundation

enum ConfigEditFileScope: Equatable { case rootOwned(index: Int), userOwned(index: Int) }

/// Resolution is metadata-only. A root-owned candidate still needs the original
/// root-only directory validation before any privileged content access.
struct ConfigEditFileScopeResolver {
    let searchPaths: [String]
    let owner: (String) throws -> uid_t?
    let validateRootDirectory: (String) throws -> Void

    init(searchPaths: [String] = TunnelConfigEditor.searchPaths,
         owner: @escaping (String) throws -> uid_t? = Self.ownerNoFollow,
         validateRootDirectory: @escaping (String) throws -> Void = { path in
             let fs = SecureConfigFileSystem(ownerUID: 0, allowTemporaryRoot: false)
             guard let fd = try fs.openDirectory(path) else { throw ConfigEditStoreError.unsafeConfiguration }
             close(fd)
         }) {
        self.searchPaths = searchPaths
        self.owner = owner
        self.validateRootDirectory = validateRootDirectory
    }

    func resolve(named name: String, clientUID: uid_t) throws -> ConfigEditFileScope {
        guard clientUID != 0, TunnelConfigStore.isNameShapeValid(name) else { throw ConfigEditStoreError.invalidName }
        for (index, directory) in searchPaths.enumerated() {
            guard let uid = try owner(directory + "/" + name + ".conf") else { continue }
            if uid == clientUID { return .userOwned(index: index) }
            guard uid == 0 else { throw ConfigEditStoreError.unsafeConfiguration }
            do { try validateRootDirectory(directory) }
            catch { throw ConfigEditStoreError.unsafeConfiguration }
            return .rootOwned(index: index)
        }
        throw ConfigEditStoreError.notFound
    }

    private static func ownerNoFollow(_ path: String) throws -> uid_t? {
        var metadata = stat()
        if lstat(path, &metadata) != 0 {
            if errno == ENOENT { return nil }
            throw ConfigEditStoreError.unavailable
        }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1 else { throw ConfigEditStoreError.unsafeConfiguration }
        return metadata.st_uid
    }
}
