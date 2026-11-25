import Foundation

public enum AvailabilityResult: String, Codable, Sendable { case staging = "Staging", ready = "Ready", regionMissing = "Region Missing", error = "Error" }
public enum AvailabilityOfferType: String, CaseIterable, Codable, Sendable { case subscription = "Subscription", rent = "Rent", buy = "Buy" }
public struct AvailabilityOffer: Codable, Equatable, Sendable {
  public let providerID: String
  public let providerName: String
  public let type: AvailabilityOfferType
  public let displayPriority: Int
  public init(providerID: String, providerName: String, type: AvailabilityOfferType, displayPriority: Int) {
    self.providerID = providerID; self.providerName = providerName; self.type = type; self.displayPriority = displayPriority
  }
}
public struct AvailabilitySnapshot: Codable, Equatable, Sendable {
  public let id: String
  public let media: MediaIdentity
  public let region: String
  public let checkedAt: Date
  public let result: AvailabilityResult
  public let sourceURL: URL?
  public let offers: [AvailabilityOffer]
  public init(id: String, media: MediaIdentity, region: String, checkedAt: Date, result: AvailabilityResult, sourceURL: URL?, offers: [AvailabilityOffer]) {
    self.id = id; self.media = media; self.region = region; self.checkedAt = checkedAt; self.result = result; self.sourceURL = sourceURL; self.offers = offers
  }
}
public struct AvailabilityState: Sendable {
  public let snapshot: AvailabilitySnapshot?
  public let stale: Bool
  public let uncertain: Bool
  public func matches(providerIDs: Set<String>, offerTypes: Set<AvailabilityOfferType>) -> Bool {
    if providerIDs.isEmpty && offerTypes.isEmpty { return true }
    return snapshot?.offers.contains { offer in
      (providerIDs.isEmpty || providerIDs.contains(offer.providerID)) && (offerTypes.isEmpty || offerTypes.contains(offer.type))
    } ?? false
  }
}
public enum AvailabilityPolicy {
  /// Failed refreshes keep the last complete observation for this exact title and country.
  public static func select(_ snapshots: [AvailabilitySnapshot], media: MediaIdentity, region: String, now: Date) -> AvailabilityState {
    let candidates = snapshots.filter { $0.media == media && $0.region == region && $0.result != .staging }.sorted {
      $0.checkedAt == $1.checkedAt ? $0.id > $1.id : $0.checkedAt > $1.checkedAt
    }
    let ready = candidates.first { $0.result == .ready }
    return AvailabilityState(snapshot: ready, stale: ready.map { now.timeIntervalSince($0.checkedAt) >= 86400 } ?? false, uncertain: candidates.first.map { $0.result != .ready } ?? true)
  }
}
