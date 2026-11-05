import XCTest
@testable import WGStatusBarCore

@MainActor
final class ConfigEditorModelTests: XCTestCase {
    private struct Masked: MaskedConfigReading {
        func maskedConfig(named name: String) async throws -> TunnelConfigDocument { TunnelConfigDocument(text: "masked") }
    }
    private struct Reveal: ConfigRevealExecuting {
        func reveal(named name: String, serviceState: ServiceState) async -> ConfigRevealOutcome { .cancelledByUser }
    }
    private final class Editor: ConfigEditingExecuting {
        var outcome: ConfigEditOutcome = .snapshot(ConfigEditSnapshot(text: "raw synthetic", revision: String(repeating: "a", count: 64)))
        var saveOutcome: ConfigEditOutcome = .saved
        var savedTexts: [String] = []
        func loadForEditing(named name: String, serviceState: ServiceState) async -> ConfigEditOutcome { outcome }
        func save(named name: String, revision: String, text: String, serviceState: ServiceState) async -> ConfigEditOutcome {
            savedTexts.append(text)
            return saveOutcome
        }
    }
    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Model completion not observed")
    }
    private func make(_ editor: Editor) async -> ConfigViewerModel {
        let model = ConfigViewerModel(maskedReader: Masked(), revealExecutor: Reveal(),
            serviceStateProvider: { .installed }, editExecutor: editor)
        model.show(name: "work")
        await waitFor { !model.isLoading }
        model.beginEditing()
        await waitFor { !model.isStartingEdit }
        return model
    }

    func testEditingUsesFreshRawDocumentAndRefusesSilentDirtyTransitions() async {
        let editor = Editor()
        let model = await make(editor)
        XCTAssertTrue(model.isEditing)
        XCTAssertEqual(model.draftText, "raw synthetic")
        XCTAssertFalse(model.hasUnsavedChanges)
        model.draftText = "changed"
        model.show(name: "other")
        model.reload()
        model.hideSecrets()
        model.close()
        XCTAssertEqual(model.tunnelName, "work")
        XCTAssertEqual(model.draftText, "changed")
        model.discardEdits()
        XCTAssertFalse(model.isEditing)
        XCTAssertEqual(model.draftText, "")
        XCTAssertEqual(model.displayedText, "masked")
    }

    func testSuccessSendsDraftClearsRawAndReloadsMasked() async {
        let editor = Editor()
        let model = await make(editor)
        model.draftText = "changed"
        model.saveEdits()
        model.saveEdits()
        await waitFor { !model.isSaving && !model.isLoading }
        XCTAssertEqual(editor.savedTexts, ["changed"])
        XCTAssertFalse(model.isEditing)
        XCTAssertEqual(model.draftText, "")
        XCTAssertEqual(model.mode, .masked)
    }

    func testConflictAndUnknownCommitPreserveDraftAndRequireReload() async {
        for failure in [ConfigEditFailure.conflict, .unknownCommitOutcome] {
            let editor = Editor()
            editor.saveOutcome = .failed(failure)
            let model = await make(editor)
            model.draftText = "changed"
            model.saveEdits()
            await waitFor { !model.isSaving }
            XCTAssertEqual(model.draftText, "changed")
            XCTAssertTrue(model.requiresEditReload)
            XCTAssertFalse(model.canSaveEdits)
            model.saveEdits()
            XCTAssertEqual(editor.savedTexts.count, 1)
        }
    }

    func testCancelledSaveKeepsDraftAndCancelledLoadNeverEditsMaskedText() async {
        let editor = Editor()
        editor.saveOutcome = .cancelled
        let model = await make(editor)
        model.draftText = "changed"
        model.saveEdits()
        await waitFor { !model.isSaving }
        XCTAssertEqual(model.draftText, "changed")
        XCTAssertNil(model.errorMessage)
        model.discardEdits()
        editor.outcome = .cancelled
        model.beginEditing()
        await waitFor { !model.isStartingEdit }
        XCTAssertFalse(model.isEditing)
        XCTAssertEqual(model.draftText, "")
    }

    func testDiscardConfirmationKeepsOrClearsDraftWithoutShowingSystemUI() async {
        let model = await make(Editor())
        model.draftText = "changed"
        XCTAssertFalse(ConfigViewerController.allowTransition(model: model, confirmDiscard: { false }))
        XCTAssertEqual(model.draftText, "changed")
        XCTAssertTrue(ConfigViewerController.allowTransition(model: model, confirmDiscard: { true }))
        XCTAssertEqual(model.draftText, "")
        XCTAssertFalse(model.isEditing)
    }

    func testCancellingLoadingOrRevealClearsTheirBusyFlags() {
        let model = ConfigViewerModel(maskedReader: Masked(), revealExecutor: Reveal(), serviceStateProvider: { .installed })
        model.show(name: "work")
        model.hideSecrets()
        XCTAssertFalse(model.isLoading)
        model.revealSecrets()
        model.discardEdits()
        XCTAssertFalse(model.isRevealing)
    }

    func testPostCloseCleanupCannotBeRefusedByDirtyState() async {
        let model = await make(Editor())
        model.draftText = "unsaved raw"
        model.windowDidClose()
        XCTAssertNil(model.tunnelName)
        XCTAssertEqual(model.draftText, "")
        XCTAssertEqual(model.displayedText, "")
        XCTAssertFalse(model.isEditing)
    }

    func testDirtyDetectionUsesExactBytesNotCanonicalUnicodeEquality() async {
        let editor = Editor()
        editor.outcome = .snapshot(ConfigEditSnapshot(text: "\u{00e9}", revision: String(repeating: "a", count: 64)))
        let model = await make(editor)
        model.draftText = "e\u{0301}"
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertTrue(model.canSaveEdits)
    }
}
