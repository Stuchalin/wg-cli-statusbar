import Darwin
import Foundation

public struct ConfigEditLaunch: Equatable, Sendable {
    public let name: String
    public let clientUID: uid_t
    public let clientPID: pid_t
    public let session: String
    public let saving: Bool
}

struct ConfigEditMessage: Codable, Equatable {
    enum Kind: String, Codable {
        case read, save, loaded, saved, unavailable, conflict, invalidDocument
        case unsafeConfiguration
        case activeTunnel, cancelled, busy, unknownCommitOutcome
    }
    // JSON can expand one UTF-8 control byte to six ASCII bytes.
    static let wireLimit = 6 * TunnelConfigReader.maxSizeBytes + 4096
    let kind: Kind
    var text: String? = nil
    var revision: String? = nil

    func encoded() throws -> String {
        let bytes = try JSONEncoder().encode(self)
        guard bytes.count <= Self.wireLimit, let text = String(data: bytes, encoding: .utf8) else {
            throw ConfigEditStoreError.invalidDocument
        }
        return text
    }

    static func decode(_ text: String) throws -> Self {
        guard text.utf8.count <= wireLimit else { throw ConfigEditStoreError.invalidDocument }
        return try JSONDecoder().decode(Self.self, from: Data(text.utf8))
    }

    static func validRevision(_ revision: String) -> Bool {
        revision.utf8.count == 64 && revision.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public func helperConfigEditCapabilitiesOutput() -> String {
    "config-edit \(helperProtocolVersion) \(helperBuildNumber) config-edit-v1\n"
}

/// Root authorization comes from the installed helper's administrator launch;
/// argv supplies expectations, and the kernel must authenticate the connecting process.
public func runHelperConfigEditSession(_ launch: ConfigEditLaunch) -> Int32 {
    guard geteuid() == 0, launch.clientUID != 0, launch.clientPID > 0,
          TunnelConfigStore.isNameShapeValid(launch.name),
          UUID(uuidString: launch.session)?.uuidString == launch.session else { return 2 }
    do {
        let session = try ConfigEditSession(parent: "/private/var/db", session: launch.session, owner: 0)
        try session.publishReady()
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        // A wrong peer never consumes the authorized operation or obtains data.
        while ProcessInfo.processInfo.systemUptime < deadline {
            let descriptor = try session.acceptOne(timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime))
            let channel: ConfigEditChannel
            do {
                channel = try ConfigEditChannel(descriptor: descriptor, expectedUID: launch.clientUID,
                    expectedPID: launch.clientPID, timeout: 5, limit: ConfigEditMessage.wireLimit)
            } catch ConfigEditChannel.Failure.peerRejected {
                Thread.sleep(forTimeInterval: 0.001)
                continue
            }
            let request = try ConfigEditMessage.decode(channel.receive())
            let response = performScopedConfigEditRequest(request, launch: launch)
            try channel.send(response.encoded())
            return 0
        }
    } catch { return 1 }
    return 1
}

func performConfigEditRequest(_ request: ConfigEditMessage, named name: String,
                              saving: Bool, editor: TunnelConfigEditor) -> ConfigEditMessage {
    do {
        if !saving {
            guard request.kind == .read, request.text == nil, request.revision == nil else {
                return ConfigEditMessage(kind: .unavailable)
            }
            let snapshot = try editor.readSnapshot(named: name)
            return ConfigEditMessage(kind: .loaded, text: snapshot.text, revision: snapshot.revision)
        }
        guard request.kind == .save, let text = request.text, let revision = request.revision,
              ConfigEditMessage.validRevision(revision) else { return ConfigEditMessage(kind: .invalidDocument) }
        try editor.save(named: name, revision: revision, text: text)
        return ConfigEditMessage(kind: .saved)
    } catch let failure as ConfigEditStoreError {
        let kind: ConfigEditMessage.Kind
        switch failure {
        case .unsafeConfiguration: kind = .unsafeConfiguration
        case .conflict: kind = .conflict
        case .activeTunnel: kind = .activeTunnel
        case .invalidDocument: kind = .invalidDocument
        case .cancelled: kind = .cancelled
        case .busy: kind = .busy
        case .unknownCommitOutcome: kind = .unknownCommitOutcome
        case .invalidName, .notFound, .unavailable: kind = .unavailable
        }
        return ConfigEditMessage(kind: kind)
    } catch { return ConfigEditMessage(kind: .unavailable) }
}
