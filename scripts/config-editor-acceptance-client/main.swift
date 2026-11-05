import AppKit
import Foundation
import WGStatusBarCore

// Exercises the installed helper through the same public API as the editor.
// Only the nonce-scoped synthetic fixture is accepted. No raw document output.
@main
struct AcceptanceClient {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 2 else { exit(1) }
        let action = arguments[0]
        let name = arguments[1]
        guard name.hasPrefix("editqa-"), name.utf8.count == 15,
              name.utf8.dropFirst(7).allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { exit(1) }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let editor = PrivilegedConfigEditor()
        let loaded = await editor.loadForEditing(named: name, serviceState: .installed)
        guard case .snapshot(let snapshot) = loaded else { fail(loaded) }
        guard snapshot.text.contains("WGStatusBar isolated editor QA; NEVER CONNECT"),
              snapshot.text.contains(configSecretCanary) else {
            print("FAIL: fixture identity")
            exit(1)
        }
        print("PASS: fresh authenticated synthetic snapshot")
        fflush(stdout)
        if action == "--save" {
            let result = await editor.save(named: name, revision: snapshot.revision,
                text: snapshot.text + "# Saved via editor QA\n", serviceState: .installed)
            finish(result, expected: .saved)
        } else if action == "--conflict", arguments.count == 3 {
            print("SNAPSHOT_READY")
            fflush(stdout)
            let deadline = ProcessInfo.processInfo.systemUptime + 120
            while !FileManager.default.fileExists(atPath: arguments[2]) {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    print("FAIL: conflict coordination timeout")
                    exit(1)
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            let result = await editor.save(named: name, revision: snapshot.revision,
                text: snapshot.text + "# Must not overwrite external QA change\n", serviceState: .installed)
            finish(result, expected: .failed(.conflict))
        } else if action == "--load" || action == "--reload" {
            if action == "--reload", !snapshot.text.contains("# External acceptance update") {
                print("FAIL: reload did not fetch external change")
                exit(1)
            }
            print("PASS: authenticated reload")
        } else { exit(1) }
    }

static func finish(_ result: ConfigEditOutcome, expected: ConfigEditOutcome) {
        if result == expected {
            print(expected == .saved ? "PASS: installed-helper Save" : "PASS: installed-helper conflict refused")
            return
        }
        fail(result)
    }

    static func fail(_ result: ConfigEditOutcome) -> Never {
        switch result {
        case .cancelled: print("CANCELLED: authentication or administrator prompt")
        case .suppressed: print("FAIL: operation suppressed")
        case .failed(let error): print("FAIL: " + String(describing: error))
        case .saved: print("FAIL: unexpected Save")
        case .snapshot: print("FAIL: unexpected snapshot")
        }
        exit(1)
    }
}
