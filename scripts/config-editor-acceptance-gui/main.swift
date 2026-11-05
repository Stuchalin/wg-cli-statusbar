import AppKit
import WGStatusBarCore

// Hosts the production controller/view unchanged, restricted to one synthetic
// fixture. No status model, tunnel controls, or real-configuration navigation.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 1 else { exit(1) }
let qaName = arguments[0]
guard qaName.hasPrefix("editqa-"), qaName.utf8.count == 15,
      qaName.utf8.dropFirst(7).allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { exit(1) }

final class QAGUIDelegate: NSObject, NSApplicationDelegate {
    private var viewer: ConfigViewerController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = ConfigViewerModel(maskedReader: SocketConfigClient(), revealExecutor: PrivilegedConfigReader(),
            serviceStateProvider: { .installed }, editExecutor: PrivilegedConfigEditor())
        viewer = ConfigViewerController(model: model)
        let menu = NSMenu()
        let item = NSMenuItem()
        let appMenu = NSMenu(title: "Editor QA")
        let reopen = NSMenuItem(title: "Reopen QA Configuration", action: #selector(openQA), keyEquivalent: "o")
        reopen.target = self
        appMenu.addItem(reopen)
        let quit = NSMenuItem(title: "Quit Editor QA", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)
        item.submenu = appMenu
        menu.addItem(item)
        NSApp.mainMenu = menu
        openQA()
    }
    @objc func openQA() { viewer?.showConfig(named: qaName) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        viewer?.prepareForApplicationTermination() == false ? .terminateCancel : .terminateNow
    }
}
let app = NSApplication.shared
let delegate = QAGUIDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
