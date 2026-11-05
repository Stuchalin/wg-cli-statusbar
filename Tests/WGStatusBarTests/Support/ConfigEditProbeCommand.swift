import CryptoKit
import Darwin
import Foundation

enum ConfigEditProbeCommand {
static func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
static func privilegedArguments(executable: String, uid: uid_t, pid: pid_t, session: String) throws -> [String] {
    let digest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: executable)))
        .map { String(format: "%02x", $0) }.joined()
    // Copy into an exclusive root-owned directory and verify the copied bytes,
    // not a user-writable source path, before executing the authorized probe.
    let command = "set -eu; d=$(/usr/bin/mktemp -d /private/var/db/wge-code.XXXXXXXX); "
        + "trap '/bin/rm -f \"$d/probe\"; /bin/rmdir \"$d\"' EXIT; "
        + "/usr/bin/install -o root -g wheel -m 0700 " + shellQuoted(executable) + " \"$d/probe\"; "
        + "sum=$(/usr/bin/shasum -a 256 \"$d/probe\"); test \"${sum%% *}\" = " + shellQuoted(digest) + "; "
        + "\"$d/probe\" --serve " + String(uid) + " " + String(pid) + " " + shellQuoted(session)
    let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return ["-e", "do shell script \"" + escaped + "\" with administrator privileges"]
}
}
