import XCTest

@MainActor final class MediaCenterUITests: XCTestCase {
  private var app: XCUIApplication!
  override func setUp() async throws {
    await MainActor.run {
      continueAfterFailure = false
      app = XCUIApplication()
      app.launchArguments = ["--synthetic", "--test-id", UUID().uuidString]
      app.launch()
    }
  }
  override func tearDown() async throws { await MainActor.run { app.terminate() } }
  private func press(_ identifier: String) {
    let button: XCUIElement
    #if os(macOS)
    button = identifier.hasPrefix("filter.") ? app.checkBoxes[identifier] : app.buttons[identifier]
    #else
    button = identifier.hasPrefix("filter.") ? app.switches[identifier] : identifier.hasPrefix("nav.") ? app.tabBars.buttons[String(identifier.dropFirst(4)).capitalized] : app.buttons[identifier]
    #endif
    XCTAssertTrue(button.waitForExistence(timeout: 10), identifier)
    button.tap()
  }
  func testNativeNavigationAndMixedFeedFilters() {
    press("nav.library")
    XCTAssertTrue(app.staticTexts["The quiet city"].waitForExistence(timeout: 10))
    press("nav.history")
    XCTAssertTrue(app.staticTexts["A finished story"].waitForExistence(timeout: 10))
    press("nav.feed")
    press("feed.filters")
    press("filter.article")
    press("filters.done")
    XCTAssertTrue(app.staticTexts["The quiet city"].exists)
    XCTAssertFalse(app.staticTexts["North Shore"].exists)
  }
  func testTVShowExpandsIntoEpisodes() {
    press("item.tvShow.show-one")
    XCTAssertTrue(app.staticTexts["First light"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Second tide"].exists)
  }
  func testAddRequiresResolvedSavedReceipt() {
    press("media.add")
    let input = app.textViews["capture.input"]
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    input.tap()
    input.typeText("Save https://example.test/new-article")
    press("capture.save")
    XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 10))
    press("capture.done")
    XCTAssertTrue(app.staticTexts["A newly saved article"].waitForExistence(timeout: 10))
  }
  func testOpenReturnAndDismissNeverMarksConsumed() {
    press("item.youtubeVideo.video-one")
    press("media.open")
    press("synthetic.return")
    press("review.unchanged")
    XCTAssertEqual(app.staticTexts["fixture.writes"].label, "Writes: 0")
    XCTAssertTrue(app.staticTexts["Unseen"].exists)
  }
  func testReadOnlySourceFactsHaveNoEditors() {
    press("item.youtubeVideo.video-one")
    XCTAssertFalse(app.textFields["edit.title"].exists)
    XCTAssertFalse(app.textFields["edit.duration"].exists)
    XCTAssertTrue(app.buttons["media.save"].exists)
  }
  func testUserNotesAreExplicitlyApplied() {
    press("item.youtubeVideo.video-one")
    press("media.fields")
    let notes = app.textViews["edit.note"]
    XCTAssertTrue(notes.waitForExistence(timeout: 10))
    notes.tap(); notes.typeText("Keep this for the weekend")
    XCTAssertEqual(app.staticTexts["fixture.writes"].label, "Writes: 0")
    press("fields.apply")
    XCTAssertTrue(app.staticTexts["Updated"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.staticTexts["fixture.writes"].label, "Writes: 1")
  }
  func testSeasonBulkShowsPartialReceipts() {
    press("item.tvShow.show-one")
    press("season.1.finish")
    XCTAssertTrue(app.staticTexts["2 aired episodes"].waitForExistence(timeout: 10))
    press("season.confirm")
    XCTAssertTrue(app.staticTexts["1 of 2 updated"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Could not update Second tide"].exists)
  }
}
