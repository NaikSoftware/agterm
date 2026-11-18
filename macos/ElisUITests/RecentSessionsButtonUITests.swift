import XCTest

/// End-to-end tests for the title-bar switcher pill (`recent-sessions-button`) — the mouse equivalent of the
/// Ctrl-Tab switcher. It opens a popover of attention, recent and recently closed sessions; clicking a row
/// commits the switch. The pill is disabled while all three lists are empty.
///
/// SCOPE NOTE (the bell popover): the row CLICK → session switch cannot be driven from XCUITest — a synthesized click (element
/// OR coordinate) on a SwiftUI `Button` inside an `NSPopover` does not fire the button's action (confirmed
/// by instrumenting the row action: the marker never wrote), while a real mouse click does, because it makes
/// the popover key. So these tests cover the enable/disable state and that the popover OPENS and LISTS the
/// correct previous session; the click → `selectSession` glue is verified by hand (see ui-tests.md).
@MainActor
final class RecentSessionsButtonUITests: ControlAPITestCase {
    func testSwitcherOpensWithOnlyTheSearchFieldInASingleSessionWindow() throws {
        let button = app.buttons["recent-sessions-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the switcher pill should render in the title bar")
        XCTAssertTrue(pollEnabled(button, true, timeout: 8), "the search field can always act, so the pill stays enabled")

        let field = openSwitcher(button)
        XCTAssertTrue(field.exists, "clicking the pill should open the switcher with its search field")
        XCTAssertEqual(app.buttons.matching(identifier: "recent-session-row").count, 0)
    }

    func testTypingFiltersTheSwitcherAndReturnSwitches() throws {
        let seeded = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(seeded)","args":{"name":"zebrafish"}}"#)["ok"] as? Bool, true)
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let newID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        XCTAssertTrue(pollActiveSessionID(try XCTUnwrap(UUID(uuidString: newID)), timeout: 8))

        let field = openSwitcher(app.buttons["recent-sessions-button"])
        XCTAssertTrue(field.exists)
        // typed without clicking the field: it holds the keyboard from the moment the popover opens
        for key in "zebra" { app.typeKey(String(key), modifierFlags: []) }
        XCTAssertEqual(field.value as? String, "zebra", "the field should hold the keyboard without a click")
        let rows = app.buttons.matching(identifier: "recent-session-row")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !(rows.count == 1 && rows.firstMatch.label.contains("zebrafish")) { usleep(100_000) }
        XCTAssertEqual(rows.count, 1, "the query should filter the list to the matching session")
        XCTAssertTrue(rows.firstMatch.label.contains("zebrafish"), "filtered row: \(rows.firstMatch.label)")

        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(pollActiveSessionID(try XCTUnwrap(UUID(uuidString: seeded)), timeout: 8),
                      "Return should switch to the highlighted session")
    }

    // the previous session gets a unique rename so its jump row can be told apart by label.
    func testRecentButtonPopoverListsPreviousSession() throws {
        let seeded = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(seeded)","args":{"name":"prevsession"}}"#)["ok"] as? Bool,
                       true, "renaming the seeded session should succeed")

        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let newID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return the new id")
        XCTAssertTrue(pollActiveSessionID(try XCTUnwrap(UUID(uuidString: newID)), timeout: 8), "the new session should be selected")

        let button = app.buttons["recent-sessions-button"]
        XCTAssertTrue(pollEnabled(button, true, timeout: 8), "two sessions should enable the recent-sessions button")

        let jumpRow = openPopoverJumpRow(button: button, timeout: 10)
        XCTAssertTrue(jumpRow.exists, "clicking the button should open the popover with the previous session as a jump row")
        XCTAssertTrue(jumpRow.label.contains("prevsession"),
                      "the jump row should be the previously-selected (renamed) session, got label: \(jumpRow.label)")
        XCTAssertEqual(app.buttons.matching(identifier: "recent-session-row").count, 1,
                       "the popover should list only the single other session, not the current one")
    }

    func testControlPOpensTheSwitcherOverlayUnderThePill() throws {
        let pill = app.buttons["recent-sessions-button"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        try assertControlPSwitches { field in
            XCTAssertEqual(field.frame.midX, pill.frame.midX, accuracy: 40, "the switcher hangs centred under the pill")
            XCTAssertEqual(field.frame.minY - pill.frame.maxY, 20, accuracy: 30, "the switcher hangs right under the pill")
        }
    }

    func testControlPOpensTheSwitcherOverlayWithoutThePill() throws {
        try relaunch(withSettings: #"{"hiddenInterfaceElements":["recentSessions"]}"#)
        XCTAssertFalse(app.buttons["recent-sessions-button"].exists, "the setting should hide the pill")
        try assertControlPSwitches()
    }

    /// ⌃P opens the switcher overlay with its field focused: the typed query filters the list and Return switches.
    private func assertControlPSwitches(placement: (XCUIElement) -> Void = { _ in }) throws {
        let seeded = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(seeded)","args":{"name":"zebrafish"}}"#)["ok"] as? Bool, true)
        // two other sessions, so the filtered list (one row) differs from the unfiltered Recent list (two)
        _ = try sendCommand(#"{"cmd":"session.new"}"#)
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let newID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        XCTAssertTrue(pollActiveSessionID(try XCTUnwrap(UUID(uuidString: newID)), timeout: 8))

        let field = app.textFields["switcher-search-field"]
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !field.exists {
            app.typeKey("p", modifierFlags: [.control])
            _ = field.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(field.exists, "⌃P should open the session switcher")
        XCTAssertTrue(app.descendants(matching: .any)["switcher-scrim"].exists, "⌃P shows the switcher overlay")
        placement(field)

        let rows = app.buttons.matching(identifier: "recent-session-row")
        for key in "zebra" { app.typeKey(String(key), modifierFlags: []) }
        let filtered = Date().addingTimeInterval(5)
        while Date() < filtered, !(rows.count == 1 && rows.firstMatch.label.contains("zebrafish")) { usleep(100_000) }
        XCTAssertEqual(field.value as? String, "zebra", "the field should hold the keyboard without a click")
        XCTAssertEqual(rows.count, 1, "the query should filter the list to the matching session")

        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(pollActiveSessionID(try XCTUnwrap(UUID(uuidString: seeded)), timeout: 8),
                      "Return should switch to the highlighted session")
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "a commit closes the switcher")
    }

    func testRecentButtonListsAClosedSessionAlone() throws {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let newID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(newID)","args":{"name":"closedone"}}"#)["ok"] as? Bool, true)
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.close","target":"\#(newID)"}"#)["ok"] as? Bool, true)

        let button = app.buttons["recent-sessions-button"]
        XCTAssertTrue(pollEnabled(button, true, timeout: 8), "a closed session alone should enable the button")
        let row = app.buttons["recent-closed-row"]
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !row.exists {
            button.click()
            _ = row.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(row.label.contains("closedone"), "closed row: \(row.label)")
        XCTAssertEqual(app.buttons.matching(identifier: "recent-session-row").count, 0)
    }

    func testPopoversNameACompanionAfterItsParent() throws {
        try relaunch(withSettings: #"{"attentionButtonEnabled":true}"#)
        let parent = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(parent)","args":{"name":"api"}}"#)["ok"] as? Bool, true)
        let row = app.staticTexts["session-row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.rightClick()
        let item = app.menuItems.matching(identifier: "New Companion").allElementsBoundByIndex.first { $0.isHittable }
        try XCTUnwrap(item, "the row menu should offer New Companion").click()
        let companion = try XCTUnwrap(pollSecondSessionID(timeout: 8), "New Companion should add a session")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(companion)","args":{"name":"logs"}}"#)["ok"] as? Bool, true)
        _ = try sendCommand(#"{"cmd":"session.status","target":"\#(companion)","args":{"status":"blocked"}}"#)
        _ = try sendCommand(#"{"cmd":"session.select","target":"\#(parent)"}"#)

        let recent = app.buttons["recent-sessions-button"]
        XCTAssertTrue(pollEnabled(recent, true, timeout: 8))
        XCTAssertTrue(openSwitcher(recent).exists)
        let needsYou = app.buttons["attention-session-row"]
        XCTAssertTrue(needsYou.waitForExistence(timeout: 5), "the switcher should list the blocked companion under Needs you")
        XCTAssertTrue(needsYou.label.contains("api › logs"), "switcher attention row: \(needsYou.label)")
        // the companion is also the most recent other session; it is listed once, under Needs you
        XCTAssertEqual(app.buttons.matching(identifier: "attention-session-row").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "recent-session-row").count, 0,
                       "a session Needs you lists must not repeat under Recent")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        // the switcher's own search field tells its popover apart from the bell's, which share attention rows.
        let bell = app.buttons["attention-button"]
        let attentionRow = app.buttons["attention-session-row"]
        let switcherJump = app.textFields["switcher-search-field"]
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !attentionRow.exists || switcherJump.exists {
            bell.click()
            _ = attentionRow.waitForExistence(timeout: 1)
        }
        XCTAssertFalse(switcherJump.exists, "the bell's popover, not the switcher's, should be open")
        XCTAssertTrue(attentionRow.label.contains("api › logs"), "bell popover row: \(attentionRow.label)")
    }

    private func pollSecondSessionID(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let tree = (try? sendCommand(#"{"cmd":"tree"}"#))?["result"] as? [String: Any]
            let ws = ((tree?["tree"] as? [String: Any])?["workspaces"] as? [[String: Any]])?.first
            if let sessions = ws?["sessions"] as? [[String: Any]], sessions.count == 2 {
                return sessions[1]["id"] as? String
            }
            usleep(200_000)
        }
        return nil
    }

    /// Clicks the pill until the switcher's search field appears, returning it (non-existent on timeout).
    private func openSwitcher(_ button: XCUIElement) -> XCUIElement {
        let field = app.textFields["switcher-search-field"]
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !field.exists {
            button.click()
            _ = field.waitForExistence(timeout: 1)
        }
        return field
    }

    /// (Re)opens the recent-sessions popover until its jump row appears, returning it (or a non-existent
    /// element on timeout). The transient popover can dismiss before the first snapshot, so retry the open;
    /// a click is only issued while no row is showing, so it never toggles an already-open popover shut.
    private func openPopoverJumpRow(button: XCUIElement, timeout: TimeInterval) -> XCUIElement {
        let row = app.buttons["recent-session-row"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if row.exists { return row }
            button.click()
            if row.waitForExistence(timeout: 1) { return row }
        }
        return row
    }

    /// Polls until `element`'s enabled state matches `expected` (the live observation lag after the session
    /// set changes over the socket), bounded by `timeout`.
    private func pollEnabled(_ element: XCUIElement, _ expected: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.isEnabled == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.exists && element.isEnabled == expected
    }
}
