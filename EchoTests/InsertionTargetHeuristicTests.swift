import XCTest
@testable import Echo

final class InsertionTargetHeuristicTests: XCTestCase {
    private func decide(
        secureInput: Bool = false,
        focusedElementExists: Bool = true,
        role: String? = nil,
        valueSettable: Bool = false,
        selectedTextRangeSettable: Bool = false
    ) -> Bool {
        InsertionTargetHeuristic.hasTarget(
            secureInput: secureInput,
            focusedElementExists: focusedElementExists,
            role: role,
            valueSettable: valueSettable,
            selectedTextRangeSettable: selectedTextRangeSettable
        )
    }

    // MARK: - Clear positives

    func testTextRolesAreTargets() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
            XCTAssertTrue(decide(role: role), role)
        }
    }

    func testSettableValueIsTarget() {
        XCTAssertTrue(decide(role: "AXUnknown", valueSettable: true))
    }

    func testSelectedTextRangeIsTarget() {
        XCTAssertTrue(decide(role: "AXWebArea", selectedTextRangeSettable: true))
    }

    // MARK: - The Electron regression: containers and unknowns must paste

    func testElectronContainerRolesStillPaste() {
        // Electron/Chromium apps report the window or a bare group for real
        // text fields until their AX tree is enabled — these must paste.
        for role in ["AXWindow", "AXGroup", "AXWebArea", "AXSplitGroup", "AXTabGroup", "AXToolbar"] {
            XCTAssertTrue(decide(role: role), role)
        }
    }

    func testUnknownOrMissingRolePastes() {
        XCTAssertTrue(decide(role: nil))
        XCTAssertTrue(decide(role: "AXSomethingNew"))
    }

    func testNoFocusedElementPastes() {
        // Apps with no AX support report no focused element; uncertainty
        // must not withhold the paste.
        XCTAssertTrue(decide(focusedElementExists: false))
    }

    // MARK: - Confident negatives → copy pill

    func testSecureInputIsNeverATarget() {
        XCTAssertFalse(decide(secureInput: true, role: "AXTextField", valueSettable: true))
    }

    func testLeafControlsAreNotTargets() {
        for role in ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
                     "AXMenuItem", "AXStaticText", "AXImage", "AXSlider", "AXLink"] {
            XCTAssertFalse(decide(role: role), role)
        }
    }

    func testDesktopAndFileListsAreNotTargets() {
        for role in ["AXScrollArea", "AXList", "AXTable", "AXOutline"] {
            XCTAssertFalse(decide(role: role), role)
        }
    }
}
