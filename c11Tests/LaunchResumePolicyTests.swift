import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-559: c11 resumes the previous session by default. The picker is the
/// explicit choice (Settings "Ask", or Option held at launch for one launch),
/// and QA launches keep their deterministic overrides.
final class LaunchResumePolicyTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "c11.LaunchResumePolicyTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func resolve(
        qa: QALaunchPolicy = .off,
        stored: String?,
        devBuild: Bool = false,
        option: Bool = false
    ) -> LaunchResumePolicy {
        if let stored {
            defaults.set(stored, forKey: LaunchResumePolicy.defaultsKey)
        } else {
            defaults.removeObject(forKey: LaunchResumePolicy.defaultsKey)
        }
        return LaunchResumePicker.resolveEffectivePolicy(
            qa: qa,
            persisted: LaunchResumePolicy.current(defaults: defaults),
            isLocalDevBuild: devBuild,
            optionHeld: option
        )
    }

    // MARK: Stored preference

    func testAbsentPreferenceResumesSilently() {
        XCTAssertEqual(LaunchResumePolicy.current(defaults: defaults), .always)
        XCTAssertEqual(resolve(stored: nil), .always)
    }

    func testEmptyOrUnknownPreferenceResumesSilently() {
        XCTAssertEqual(resolve(stored: ""), .always)
        XCTAssertEqual(resolve(stored: "   "), .always)
        XCTAssertEqual(resolve(stored: "sometimes"), .always)
    }

    func testStoredValuesAreHonored() {
        XCTAssertEqual(resolve(stored: "always"), .always)
        XCTAssertEqual(resolve(stored: "ask"), .ask)
        XCTAssertEqual(resolve(stored: "never"), .never)
        XCTAssertEqual(resolve(stored: " Never \n"), .never)
    }

    func testParseMatchesStoredRead() {
        for raw in [nil, "", "ask", "ALWAYS", "never", "bogus"] as [String?] {
            if let raw {
                defaults.set(raw, forKey: LaunchResumePolicy.defaultsKey)
            } else {
                defaults.removeObject(forKey: LaunchResumePolicy.defaultsKey)
            }
            XCTAssertEqual(LaunchResumePolicy.parse(raw), LaunchResumePolicy.current(defaults: defaults))
        }
    }

    // MARK: Option held at launch

    func testOptionLaunchShowsPickerWhateverIsStored() {
        XCTAssertEqual(resolve(stored: nil, option: true), .ask)
        XCTAssertEqual(resolve(stored: "always", option: true), .ask)
        XCTAssertEqual(resolve(stored: "never", option: true), .ask)
        XCTAssertEqual(resolve(stored: nil, devBuild: true, option: true), .ask)
    }

    func testOptionLaunchIsNeverPersisted() {
        defaults.removeObject(forKey: LaunchResumePolicy.defaultsKey)
        _ = LaunchResumePicker.resolveEffectivePolicy(
            qa: .off,
            persisted: LaunchResumePolicy.current(defaults: defaults),
            isLocalDevBuild: false,
            optionHeld: true
        )
        XCTAssertNil(defaults.object(forKey: LaunchResumePolicy.defaultsKey))
        XCTAssertEqual(resolve(stored: nil, option: false), .always)
    }

    // MARK: QA and dev builds (unchanged)

    func testQAOverridesBeatOptionAndStoredPolicy() {
        for stored in [nil, "ask", "always", "never"] as [String?] {
            for option in [false, true] {
                XCTAssertEqual(resolve(qa: .on(.resume), stored: stored, option: option), .always)
                XCTAssertEqual(resolve(qa: .on(.fresh), stored: stored, option: option), .never)
            }
        }
    }

    func testDevBuildStillTurnsStoredAskIntoSilentRestore() {
        XCTAssertEqual(resolve(stored: "ask", devBuild: true), .always)
        XCTAssertEqual(resolve(stored: nil, devBuild: true), .always)
        XCTAssertEqual(resolve(stored: "never", devBuild: true), .never)
    }
}
