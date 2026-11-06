import Darwin
import Foundation

public enum ConfigEditFailure: Error, Equatable {
    case privileged(PrivilegedConfigError)
    case unsafeConfiguration
    case unavailable, invalidDocument, conflict, activeTunnel, busy, unknownCommitOutcome

    public var userMessage: String {
        if case .privileged(let error) = self { return error.userMessage }
        let key: String
        switch self {
        case .unsafeConfiguration: key = "unsafe_configuration"
        case .invalidDocument: key = "invalid_document"
        case .conflict: key = "conflict"
        case .activeTunnel: key = "active_tunnel"
        case .busy: key = "busy"
        case .unknownCommitOutcome: key = "unknown_commit"
        case .unavailable, .privileged: key = "unavailable"
        }
        return L10n.string("config.editor.error." + key)
    }
}

public enum ConfigEditOutcome: Equatable {
    case snapshot(ConfigEditSnapshot), saved, cancelled, suppressed, failed(ConfigEditFailure)
}

public protocol ConfigEditingExecuting {
    func loadForEditing(named name: String, serviceState: ServiceState) async -> ConfigEditOutcome
    func save(named name: String, revision: String, text: String, serviceState: ServiceState) async -> ConfigEditOutcome
}

public final class PrivilegedConfigEditor: ConfigEditingExecuting {
    private let fileSystem: PrivilegedHelperProbingFileSystem
    private let processRunner: PrivilegedProcessRunning
    private let authenticator: ConfigRevealAuthenticating
    private let exchange: ConfigEditSessionExchanging
    private let claimLock = NSLock()
    private var claimed = false

    public convenience init() {
        self.init(fileSystem: PosixPrivilegedHelperProbingFileSystem(), processRunner: ProcessPrivilegedRunner(),
            authenticator: LocalAuthenticationConfigAuthenticator(), exchange: ConfigEditExchange())
    }

    init(fileSystem: PrivilegedHelperProbingFileSystem, processRunner: PrivilegedProcessRunning,
         authenticator: ConfigRevealAuthenticating, exchange: ConfigEditSessionExchanging) {
        self.fileSystem = fileSystem
        self.processRunner = processRunner
        self.authenticator = authenticator
        self.exchange = exchange
    }

    public func loadForEditing(named name: String, serviceState: ServiceState) async -> ConfigEditOutcome {
        await perform(named: name, message: ConfigEditMessage(kind: .read), serviceState: serviceState)
    }

    public func save(named name: String, revision: String, text: String, serviceState: ServiceState) async -> ConfigEditOutcome {
        guard ConfigEditMessage.validRevision(revision), text.utf8.count <= TunnelConfigReader.maxSizeBytes,
              !text.utf8.contains(0) else { return .failed(.invalidDocument) }
        return await perform(named: name, message: ConfigEditMessage(kind: .save, text: text, revision: revision), serviceState: serviceState)
    }

    private func perform(named name: String, message: ConfigEditMessage, serviceState: ServiceState) async -> ConfigEditOutcome {
        guard beginClaim() else { return .suppressed }
        defer { endClaim() }
        guard serviceState == .installed else {
            return .failed(.privileged(serviceState == .absent ? .serviceInstallRequired : .serviceUpdateRequired))
        }
        guard TunnelConfigStore.isNameShapeValid(name) else { return .failed(.privileged(.invalidName)) }
        for parent in ["/", "/Library"] {
            if let failure = PrivilegedConfigReader.preflightDirectoryFailure(fileSystem.statEntry(atPath: parent)) {
                return .failed(.privileged(failure))
            }
        }
        if let failure = PrivilegedConfigReader.preflightDirectoryFailure(fileSystem.statEntry(atPath: InstalledHelperPaths.directory))
            ?? PrivilegedConfigReader.preflightBinaryFailure(fileSystem.statEntry(atPath: InstalledHelperPaths.binary)) {
            return .failed(.privileged(failure))
        }
        for flag in ["--capabilities", "--config-edit-capabilities"] {
            if Task.isCancelled { return .cancelled }
            let outcome = await processRunner.run([InstalledHelperPaths.binary, flag], timeout: 5, maxCollectedBytes: 4096)
            switch outcome {
            case .success(let output):
                if flag == "--capabilities" {
                    if let failure = PrivilegedConfigReader.parseCapabilitiesOutput(output) { return .failed(.privileged(failure)) }
                } else if let failure = Self.validateEditorCapabilities(output) { return .failed(.privileged(failure)) }
            case .failure(.cancelled): return .cancelled
            case .promptCancelled, .failure: return .failed(.privileged(.helperUnavailable))
            }
        }
        let saving = message.kind == .save
        switch await authenticator.authenticate(reason: L10n.string(saving ? "config.auth.save_reason" : "config.auth.edit_reason")) {
        case .success: break
        case .userCancelled: return .cancelled
        case .unavailable: return .failed(.privileged(.authenticationUnavailable))
        case .failed: return .failed(.privileged(.authenticationFailed))
        }
        if Task.isCancelled { return .cancelled }
        let launch = ConfigEditLaunch(name: name, clientUID: geteuid(), clientPID: getpid(),
            session: UUID().uuidString, saving: saving)
        switch await exchange.exchange(launch: launch, message: message, runner: processRunner) {
        case .cancelledBeforeRequest: return .cancelled
        case .unavailableBeforeRequest: return .failed(.unavailable)
        case .uncertainAfterRequest: return .failed(saving ? .unknownCommitOutcome : .unavailable)
        case .reply(let reply):
            if !saving, reply.kind == .loaded, let text = reply.text, let revision = reply.revision,
               text.utf8.count <= TunnelConfigReader.maxSizeBytes, !text.utf8.contains(0), ConfigEditMessage.validRevision(revision) {
                return .snapshot(ConfigEditSnapshot(text: text, revision: revision))
            }
            if saving, reply.kind == .saved, reply.text == nil, reply.revision == nil { return .saved }
            switch reply.kind {
            case .unsafeConfiguration: return .failed(.unsafeConfiguration)
            case .conflict: return .failed(.conflict)
            case .activeTunnel: return .failed(.activeTunnel)
            case .invalidDocument: return .failed(.invalidDocument)
            case .busy: return .failed(.busy)
            case .unknownCommitOutcome: return .failed(.unknownCommitOutcome)
            case .cancelled: return .cancelled
            case .unavailable: return .failed(.unavailable)
            default: return .failed(saving ? .unknownCommitOutcome : .unavailable)
            }
        }
    }

    private func beginClaim() -> Bool {
        claimLock.lock()
        defer { claimLock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }

    private func endClaim() { claimLock.lock(); claimed = false; claimLock.unlock() }

    static func validateEditorCapabilities(_ output: String) -> PrivilegedConfigError? {
        guard output.hasSuffix("\n") else { return .helperUnavailable }
        let line = String(output.dropLast())
        guard !line.contains("\n"), !line.contains("\r") else { return .helperUnavailable }
        let fields = line.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 4, fields[0] == "config-edit", fields[3] == "config-edit-v1",
              let version = Int(fields[1]), let build = Int(fields[2]) else { return .helperUnavailable }
        return version == helperProtocolVersion && build >= helperBuildNumber ? nil : .helperOutdated
    }
}
