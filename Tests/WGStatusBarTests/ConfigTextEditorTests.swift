import AppKit
import SwiftUI
import XCTest
@testable import WGStatusBarCore

@MainActor
final class ConfigTextEditorTests: XCTestCase {
    func testPlainTextWidgetDisablesUndoAndAutomaticSubstitutions() {
        _ = NSApplication.shared
        let view = ConfigTextEditor.makeEditor(delegate: nil)
        XCTAssertFalse(view.isRichText)
        XCTAssertFalse(view.allowsUndo)
        XCTAssertFalse(view.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(view.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(view.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(view.isAutomaticSpellingCorrectionEnabled)
        XCTAssertFalse(view.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(view.isGrammarCheckingEnabled)
        XCTAssertFalse(view.isAutomaticLinkDetectionEnabled)
    }

    func testCoordinatorPreservesExactBytesAndDismantleClearsBackingText() {
        _ = NSApplication.shared
        var text = "\u{00e9}"
        let editor = ConfigTextEditor(text: Binding(get: { text }, set: { text = $0 }), isEditable: true)
        let coordinator = ConfigTextEditor.Coordinator(editor)
        let view = ConfigTextEditor.makeEditor(delegate: coordinator)
        view.string = "e\u{0301}"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        XCTAssertEqual(Array(text.utf8), Array("e\u{0301}".utf8))
        let scroll = NSScrollView()
        scroll.documentView = view
        ConfigTextEditor.dismantleNSView(scroll, coordinator: coordinator)
        XCTAssertEqual(view.string, "")
        XCTAssertNil(view.delegate)
    }

func testAppKitMenuDispatchesCommandSIntoTheSaveTarget() throws {
        _ = NSApplication.shared
        let menu = NSMenu()
        let target = SaveTarget()
        let item = ConfigViewerController.installSaveCommand(in: menu, target: target, action: #selector(SaveTarget.save(_:)))
        XCTAssertEqual(item.keyEquivalent, "s")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: 0, context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
        XCTAssertTrue(menu.performKeyEquivalent(with: event))
        XCTAssertEqual(target.calls, 1)
        item.isEnabled = false
        item.menu?.autoenablesItems = false
        _ = menu.performKeyEquivalent(with: event)
        XCTAssertEqual(target.calls, 1)
    }

func testSaveCommandInstallationIsIdempotentAndKeepsOtherShortcuts() throws {
        _ = NSApplication.shared
        let menu = NSMenu()
        let target = SaveTarget()
        let first = ConfigViewerController.installSaveCommand(in: menu, target: target, action: #selector(SaveTarget.save(_:)))
        let second = ConfigViewerController.installSaveCommand(in: menu, target: target, action: #selector(SaveTarget.save(_:)))
        XCTAssertTrue(first === second)
        XCTAssertEqual(menu.items.count, 1)
        let combinations: [NSEvent.ModifierFlags] = [[], [.command, .shift], [.command, .option], [.control]]
        for modifiers in combinations {
            let characters = modifiers.contains(.shift) ? "S" : "s"
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 1))
            _ = menu.performKeyEquivalent(with: event)
        }
        XCTAssertEqual(target.calls, 0)
    }

    private final class SaveTarget: NSObject {
        var calls = 0
        @objc func save(_ sender: Any?) { calls += 1 }
    }
}
