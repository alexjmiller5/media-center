import Foundation
import XCTest
@testable import MediaKit

final class AvailabilityTests: XCTestCase {
  private let movie = MediaIdentity(kind: .movie, id: "synthetic-movie")
  private let time = Date(timeIntervalSince1970: 2_000_000_000)
  private func snapshot(_ id: String, _ region: String, _ offset: TimeInterval, _ result: AvailabilityResult, _ offers: [AvailabilityOffer] = []) -> AvailabilitySnapshot {
    AvailabilitySnapshot(id: id, media: movie, region: region, checkedAt: time.addingTimeInterval(offset), result: result, sourceURL: URL(string: "https://www.themoviedb.org/movie/123/watch"), offers: offers)
  }
  func testLatestReadyIsCountrySpecificAndFailurePreservesLastGood() {
    let offer = AvailabilityOffer(providerID: "provider-1", providerName: "Synthetic Provider", type: .subscription, displayPriority: 1)
    let rows = [snapshot("old", "US", -100, .ready, [offer]), snapshot("error", "US", -10, .error), snapshot("other-country", "GB", 0, .ready), snapshot("unpublished", "US", 0, .staging)]
    let state = AvailabilityPolicy.select(rows, media: movie, region: "US", now: time)
    XCTAssertEqual(state.snapshot?.id, "old")
    XCTAssertTrue(state.uncertain)
    XCTAssertFalse(state.stale)
    XCTAssertTrue(state.matches(providerIDs: ["provider-1"], offerTypes: [.subscription]))
    XCTAssertFalse(state.matches(providerIDs: ["provider-1"], offerTypes: [.rent]))
    XCTAssertNil(AvailabilityPolicy.select(rows, media: movie, region: "CA", now: time).snapshot)
  }
  func testEmptySuccessReplacesOldOffersAndStalenessIsDerived() {
    let rows = [snapshot("old", "US", -90000, .ready, [.init(providerID: "p", providerName: "Provider", type: .buy, displayPriority: 0)]), snapshot("empty", "US", -86401, .ready)]
    let state = AvailabilityPolicy.select(rows, media: movie, region: "US", now: time)
    XCTAssertEqual(state.snapshot?.id, "empty")
    XCTAssertTrue(state.stale)
    XCTAssertFalse(state.uncertain)
    XCTAssertFalse(state.matches(providerIDs: [], offerTypes: [.buy]))
  }
}
