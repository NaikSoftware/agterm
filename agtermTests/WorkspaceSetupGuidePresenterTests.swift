import XCTest
@testable import agterm
import agtermCore

@MainActor
final class WorkspaceSetupGuidePresenterTests: XCTestCase {
    private final class Effects: RemoteCatalogEffects {
        func attachCommand(host: String, pane: CatalogPane) -> String { "" }
        func catalogRowAdded(_: Session) {}
        func catalogRowRemoved(_: UUID) {}
        func catalogRowEnded(_: UUID) {}
        func catalogPaneNeedsAttach(_: UUID, session _: UUID) {}
        func catalogBound(_: UUID) -> Bool { true }
        func catalogStateChanged(_: RemoteCatalogMirror.State) {}
    }

    func testDueOnlyForAFreshLocalNonTestLaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agts-guide-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = WindowLibrary(directory: directory)
        let local = try XCTUnwrap(library.activeStore)
        let remote = try XCTUnwrap(library.store(for: library.newRemoteWindow(host: "box").id))
        let mirror = RemoteCatalogMirror(host: "box", store: remote, effects: Effects(), viewState: RemoteWindowViewState())
        let fresh = AppSettings()
        let done = AppSettings(workspaceGuideDone: true)
        typealias Presenter = WorkspaceSetupGuidePresenter

        XCTAssertTrue(Presenter.isDue(settings: fresh, store: local, uiTest: false, hosted: false))
        XCTAssertFalse(Presenter.isDue(settings: done, store: local, uiTest: false, hosted: false))
        XCTAssertFalse(Presenter.isDue(settings: fresh, store: remote, uiTest: false, hosted: false))
        XCTAssertFalse(Presenter.isDue(settings: fresh, store: local, uiTest: true, hosted: false))
        XCTAssertFalse(Presenter.isDue(settings: fresh, store: local, uiTest: false, hosted: true))
        withExtendedLifetime(mirror) {}
    }
}
