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
  private var ui: XCUIElement {
    #if os(macOS)
    app.windows.firstMatch
    #else
    app
    #endif
  }
  private func press(_ identifier: String) {
    let button: XCUIElement
    #if os(macOS)
    button = identifier.hasPrefix("item.") ? media(identifier) : identifier.hasPrefix("filter.") ? ui.checkBoxes[identifier] : ui.buttons[identifier]
    #else
    button = identifier.hasPrefix("filter.") ? ui.switches[identifier] : identifier.hasPrefix("nav.") ? ui.tabBars.buttons[String(identifier.dropFirst(4)).capitalized] : ui.buttons[identifier]
    #endif
    let exists = button.waitForExistence(timeout: 10)
    XCTAssertTrue(exists, identifier)
    reveal(button)
    #if os(macOS)
    if identifier.hasPrefix("item.") { button.doubleClick() } else { button.tap() }
    #else
    button.tap()
    #endif
  }
  private func media(_ id: String) -> XCUIElement {
    #if os(macOS)
    ui.descendants(matching: .any)[id].firstMatch
    #else
    ui.buttons[id].firstMatch
    #endif
  }
  private func reveal(_ element: XCUIElement) {
    #if os(iOS)
    for _ in 0..<12 {
      if element.exists && element.isHittable { return }
      ui.swipeUp()
    }
    XCTAssertTrue(element.isHittable)
    #endif
    XCTAssertTrue(element.waitForExistence(timeout: 10))
  }
  private var writes: String {
    let text = ui.staticTexts["fixture.writes"].firstMatch
    return text.label.isEmpty ? (text.value as? String) ?? "" : text.label
  }
  #if os(macOS)
  func testKeyboardSelectAllAndSaveHasExplicitReceipts() {
    let row = ui.descendants(matching: .any)["item.youtubeVideo.video-one"].firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.click()
    ui.typeKey("a", modifierFlags: .command)
    press("selection.save")
    XCTAssertTrue(ui.staticTexts["Saved 3 of 3 selected items"].waitForExistence(timeout: 10))
    XCTAssertEqual(writes, "Writes: 3")
    ui.typeKey(.return, modifierFlags: [])
    XCTAssertFalse(ui.buttons["media.save"].exists)
  }
  func testClosingTheWindowDoesNotHideTheNextLaunch() {
    XCTAssertTrue(ui.buttons["media.add"].waitForExistence(timeout: 10))
    ui.buttons["_XCUI:CloseWindow"].tap()
    app.terminate(); app.launch()
    XCTAssertTrue(ui.buttons["media.add"].waitForExistence(timeout: 10))
  }
  #endif
  func testSyntheticScreenSnapshots() {
    snapshot("feed")
    reveal(media("item.youtubeVideo.video-one"))
    press("media.add")
    let input = ui.textViews["capture.input"]
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    snapshot("capture")
    XCTAssertEqual(input.label, "Link or description to save")
    press("capture.done")
    press("item.youtubeVideo.video-one")
    XCTAssertTrue(ui.buttons["media.save"].waitForExistence(timeout: 10))
    snapshot("detail")
  }
  private func snapshot(_ name: String) {
    let shot = XCTAttachment(screenshot: ui.screenshot())
    shot.name = name; shot.lifetime = .keepAlways; add(shot)
    let tree = XCTAttachment(string: ui.debugDescription)
    tree.name = name + "-tree"; tree.lifetime = .keepAlways; add(tree)
  }
  func testNativeNavigationAndMixedFeedFilters() {
    press("nav.library")
    XCTAssertTrue(media("item.article.article-one").waitForExistence(timeout: 10))
    press("nav.history")
    XCTAssertTrue(media("item.article.article-history").waitForExistence(timeout: 10))
    press("nav.feed")
    XCTAssertTrue(media("item.tvShow.show-one").waitForExistence(timeout: 10))
    press("feed.filters")
    press("filter.article")
    press("filters.done")
    XCTAssertTrue(media("item.article.article-one").waitForExistence(timeout: 10))
    XCTAssertTrue(media("item.tvShow.show-one").waitForNonExistence(timeout: 10))
  }
  func testUnconfiguredMediaTypesAreUnavailable() {
    press("feed.filters")
    #if os(macOS)
    let movie = ui.checkBoxes["filter.movie"]
    #else
    let movie = ui.switches["filter.movie"]
    #endif
    XCTAssertTrue(movie.waitForExistence(timeout: 10))
    XCTAssertFalse(movie.isEnabled)
    XCTAssertTrue(ui.staticTexts["Film is not configured in Life Data"].exists)
  }
  func testLibrarySearchIncludesSourceTitlesWithoutWriting() {
    press("nav.library")
    XCTAssertTrue(media("item.youtubeVideo.video-one").waitForExistence(timeout: 10))
    let search = ui.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    search.tap(); search.typeText("Low Tide Studio")
    XCTAssertTrue(media("item.youtubeVideo.video-one").waitForExistence(timeout: 10))
    XCTAssertFalse(media("item.article.article-one").exists)
    XCTAssertEqual(writes, "Writes: 0")
  }
  func testTVShowExpandsIntoEpisodes() {
    reveal(media("item.tvShow.show-one"))
    XCTAssertTrue(media("item.tvShow.show-one").label.lowercased().contains("tv show"))
    press("item.tvShow.show-one")
    XCTAssertTrue(ui.staticTexts["First light"].waitForExistence(timeout: 10))
    XCTAssertTrue(ui.staticTexts["Second tide"].exists)
  }
  func testAddRequiresResolvedSavedReceipt() {
    press("media.add")
    let input = ui.textViews["capture.input"]
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    input.tap()
    input.typeText("Save https://example.test/new-article")
    press("capture.save")
    XCTAssertTrue(ui.staticTexts["Saved"].waitForExistence(timeout: 10))
    press("capture.done")
    XCTAssertTrue(ui.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "item.article.captured-")).firstMatch.waitForExistence(timeout: 10))
  }
  func testOpenReturnAndDismissNeverMarksConsumed() {
    press("item.youtubeVideo.video-one")
    press("media.open")
    press("synthetic.return")
    press("review.unchanged")
    XCTAssertEqual(writes, "Writes: 0")
    XCTAssertTrue(ui.staticTexts["Unseen"].exists)
  }
  func testReadOnlySourceFactsHaveNoEditors() {
    press("item.youtubeVideo.video-one")
    XCTAssertFalse(ui.textFields["edit.title"].exists)
    XCTAssertFalse(ui.textFields["edit.duration"].exists)
    XCTAssertTrue(ui.buttons["media.save"].exists)
  }
  func testUserNotesAreExplicitlyApplied() {
    press("item.youtubeVideo.video-one")
    press("media.fields")
    let notes = ui.textViews["edit.note"]
    XCTAssertTrue(notes.waitForExistence(timeout: 10))
    notes.tap(); notes.typeText("Keep this for the weekend")
    XCTAssertEqual(writes, "Writes: 0")
    press("fields.apply")
    XCTAssertTrue(ui.staticTexts["Updated"].waitForExistence(timeout: 10))
    XCTAssertEqual(writes, "Writes: 1")
  }
  func testUnsentCaptureCanBeRecoveredWithoutAutomaticSubmission() {
    press("media.add")
    let input = ui.textViews["capture.input"]
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    input.tap(); input.typeText("Save https://example.test/later")
    press("capture.done")
    press("media.drafts")
    let draft = ui.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "draft.capture.")).firstMatch
    XCTAssertTrue(draft.waitForExistence(timeout: 10)); draft.tap()
    XCTAssertEqual(ui.textViews["capture.input"].value as? String, "Save https://example.test/later")
    XCTAssertEqual(writes, "Writes: 0")
    press("capture.save")
    XCTAssertTrue(ui.staticTexts["Saved"].waitForExistence(timeout: 10))
    XCTAssertEqual(writes, "Writes: 1")
  }
  func testSourceFeedStartIsAvailableWithoutWritingOnOpen() {
    press("nav.sources")
    press("source.youtubeChannel.channel-one")
    XCTAssertTrue(ui.descendants(matching: .any)["source.feed-start"].firstMatch.waitForExistence(timeout: 10))
    XCTAssertEqual(writes, "Writes: 0")
    press("source.done")
    XCTAssertEqual(writes, "Writes: 0")
  }
  func testChangedProfileRequiresReconnection() {
    press("item.youtubeVideo.video-one")
    press("fixture.profile-change")
    press("media.save")
    XCTAssertTrue(ui.textFields["enroll.endpoint"].waitForExistence(timeout: 10))
    XCTAssertFalse(ui.buttons["media.save"].exists)
  }
  func testRevokedWriteHidesMediaAndRequiresReconnection() {
    press("item.youtubeVideo.video-one")
    press("fixture.revoke")
    press("media.save")
    XCTAssertTrue(ui.textFields["enroll.endpoint"].waitForExistence(timeout: 10))
    XCTAssertFalse(ui.buttons["media.save"].exists)
  }
  func testNonGregorianCalendarNeverIncludesFutureEpisodesInBulk() {
    app.terminate()
    app.launchArguments.append("--buddhist-calendar")
    app.launch()
    press("nav.library")
    press("item.tvShow.show-one")
    press("season.1.finish")
    XCTAssertTrue(ui.staticTexts["2 aired episodes"].waitForExistence(timeout: 10))
    XCTAssertEqual(writes, "Writes: 0")
  }
  func testSeasonBulkShowsPartialReceipts() {
    press("item.tvShow.show-one")
    press("season.1.finish")
    XCTAssertTrue(ui.staticTexts["2 aired episodes"].waitForExistence(timeout: 10))
    press("season.confirm")
    XCTAssertTrue(ui.staticTexts["1 of 2 updated"].waitForExistence(timeout: 10))
    XCTAssertTrue(ui.staticTexts["Could not update Second tide"].exists)
  }
}
