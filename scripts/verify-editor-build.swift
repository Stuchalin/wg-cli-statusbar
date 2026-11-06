import Foundation

// Read build artifacts only. The environment value is a synthetic fixture marker,
// never a real key. Do not print binary contents or log excerpts.
enum VerificationFailure: Error { case arguments, unsafeArtifact, canaryFound, missingResource }
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 1, let marker = ProcessInfo.processInfo.environment["WG_EDITOR_TEST_CANARY"], !marker.isEmpty else {
    throw VerificationFailure.arguments
}
let app = URL(fileURLWithPath: arguments[0]).standardizedFileURL
let bytes = Data(marker.utf8)
guard let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
    throw VerificationFailure.unsafeArtifact
}
for case let file as URL in files {
    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isSymbolicLink != true else { throw VerificationFailure.unsafeArtifact }
    if values.isRegularFile == true, try Data(contentsOf: file).range(of: bytes) != nil { throw VerificationFailure.canaryFound }
}
for path in arguments.dropFirst() {
    if try Data(contentsOf: URL(fileURLWithPath: path)).range(of: bytes) != nil { throw VerificationFailure.canaryFound }
}
let resource = app.appendingPathComponent("Contents/Resources/WGStatusBar_WGStatusBarCore.bundle").path
guard let bundle = Bundle(path: resource) else { throw VerificationFailure.missingResource }
for language in ["en", "ru"] {
    guard let path = bundle.path(forResource: language, ofType: "lproj"), let localized = Bundle(path: path) else {
        throw VerificationFailure.missingResource
    }
    let key = "config.editor.save"
    guard localized.localizedString(forKey: key, value: key, table: "Localizable") != key else { throw VerificationFailure.missingResource }
}
guard FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/WGStatusBarHelper").path) else {
    throw VerificationFailure.missingResource
}
print("PASS: complete bundle/log byte scan, bundled helper and both editor localizations")
