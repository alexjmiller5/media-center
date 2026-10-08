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
    if identifier.hasPrefix("filter.") {
      let previous = button.value as? String
      button.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
      XCTAssertTrue(button.waitForExistence(timeout: 10))
      XCTAssertNotEqual(button.value as? String, previous, "Filter switch must change before checking results")
    } else { button.tap() }
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
  private func receipt(_ state: String) -> Bool {
    // macOS exposes static text as its value, iOS as its label.
    ui.staticTexts.matching(NSPredicate(format: "identifier == %@ AND (label == %@ OR value == %@)", "capture.receipt", state, state)).firstMatch.waitForExistence(timeout: 10)
  }
  private func text(_ identifier: String) -> String {
    let text = ui.staticTexts[identifier].firstMatch
    return text.label.isEmpty ? (text.value as? String) ?? "" : text.label
  }
  private var writes: String { text("fixture.writes") }
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
    XCTAssertFalse(ui.buttons["media.save"].waitForExistence(timeout: 3), "Return opens details only for a single selection")
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
    if ProcessInfo.processInfo.environment["MEDIA_TEST_AX5"] == "1" {
      let title = ui.staticTexts["detail.title"].firstMatch
      let done = ui.buttons["Done"].firstMatch
      XCTAssertGreaterThanOrEqual(done.frame.minY, title.frame.maxY - 1, "At accessibility sizes Done stacks below the title instead of squeezing it")
    }
    snapshot("detail")
    press("media.open")
    press("synthetic.return")
    XCTAssertTrue(ui.buttons["review.unchanged"].waitForExistence(timeout: 10))
    snapshot("return-confirmation")
    press("review.unchanged")
    XCTAssertTrue(ui.buttons["review.unchanged"].waitForNonExistence(timeout: 10))
    ui.buttons["Done"].firstMatch.tap()
    reveal(media("item.tvShow.show-one"))
    #if os(iOS)
    ui.swipeUp()  // show the whole card above the tab bar
    #endif
    snapshot("tv-card")
    press("nav.library")
    XCTAssertTrue(media("item.article.article-one").waitForExistence(timeout: 10))
    snapshot("library")
    press("nav.sources")
    XCTAssertTrue(ui.buttons["Unfollow Low Tide Studio"].waitForExistence(timeout: 10))
    snapshot("sources")
    XCTAssertEqual(writes, "Writes: 0")
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
    let row = media("item.tvShow.show-one")
    let description = row.label.isEmpty ? (row.value as? String) ?? "" : row.label
    XCTAssertTrue(description.lowercased().contains("tv show"))
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
    XCTAssertTrue(receipt("Saved"))
    press("capture.done")
    XCTAssertTrue(ui.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "item.article.captured-")).firstMatch.waitForExistence(timeout: 10))
  }
  func testOpenReturnAndDismissNeverMarksConsumed() {
    press("item.youtubeVideo.video-one")
    press("media.open")
    press("synthetic.return")
    press("review.unchanged")
    XCTAssertEqual(writes, "Writes: 0")
    XCTAssertEqual(text("media.status"), "Unseen")
  }
  func testReadOnlySourceFactsHaveNoEditors() {
    press("item.youtubeVideo.video-one")
    XCTAssertTrue(ui.buttons["media.save"].waitForExistence(timeout: 10))
    press("media.fields")
    XCTAssertTrue(ui.textViews["edit.note"].waitForExistence(timeout: 10))
    XCTAssertEqual(ui.textFields.count, 0, "Title, duration and other source facts have no editors")
    XCTAssertEqual(writes, "Writes: 0")
  }
  func testSavedItemSurvivesUnfollowingWithoutChangingConsumption() {
    press("item.youtubeVideo.video-one")
    press("media.save")
    XCTAssertTrue(ui.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "media.save", "Unsave")).firstMatch.waitForExistence(timeout: 10))
    ui.buttons["Done"].firstMatch.tap()
    press("nav.sources")
    let unfollow = ui.buttons["Unfollow Low Tide Studio"]
    XCTAssertTrue(unfollow.waitForExistence(timeout: 10)); reveal(unfollow); unfollow.tap()
    XCTAssertTrue(ui.buttons["Follow Low Tide Studio"].waitForExistence(timeout: 10))
    press("nav.feed")
    press("item.youtubeVideo.video-one")
    XCTAssertEqual(ui.buttons["media.save"].label, "Unsave")
    XCTAssertEqual(text("media.status"), "Unseen")
    XCTAssertEqual(writes, "Writes: 2")
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
    XCTAssertTrue(receipt("Saved"))
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
  func testOfflineCapturePreservesInputAndDisablesSubmission() {
    app.terminate(); app.launchArguments.append("--offline"); app.launch()
    press("media.add")
    let input = ui.textViews["capture.input"]
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    input.tap(); input.typeText("Save https://example.test/offline")
    reveal(ui.buttons["capture.save"])
    XCTAssertFalse(ui.buttons["capture.save"].isEnabled)
    press("capture.done")
    XCTAssertEqual(writes, "Writes: 0")
    press("media.drafts")
    XCTAssertTrue(ui.staticTexts["Reconnect to validate access before recovering drafts."].exists)
    XCTAssertTrue(ui.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "draft.capture.")).firstMatch.exists)
  }
  func testConflictingEditShowsPreservedDraftWithoutSuccess() {
    app.terminate(); app.launchArguments.append("--conflicting-writes"); app.launch()
    press("item.youtubeVideo.video-one")
    press("media.save")
    XCTAssertTrue(ui.staticTexts["This item changed elsewhere. Review its current values before trying again."].waitForExistence(timeout: 10))
    XCTAssertEqual(ui.buttons["media.save"].label, "Save")
    XCTAssertEqual(writes, "Writes: 1", "One refused request, never replayed")
  }
  func testUncertainCaptureRequiresReadOnlyReceiptCheck() {
    app.terminate(); app.launchArguments.append("--uncertain-writes"); app.launch()
    press("media.add")
    let input = ui.textViews["capture.input"]
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    input.tap(); input.typeText("Save https://example.test/uncertain")
    press("capture.save")
    XCTAssertTrue(receipt("Awaiting confirmation"))
    reveal(ui.buttons["Check receipt"])
    ui.buttons["Check receipt"].tap()
    XCTAssertTrue(receipt("Awaiting confirmation"))
    press("capture.done")
    XCTAssertEqual(writes, "Writes: 1", "Checking a receipt never resubmits")
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
