import SwiftUI

extension ShapeStyle where Self == Color {
  /// System red falls below 4.5:1 on light backgrounds; this keeps error text readable in both appearances.
  static var errorText: Color {
    #if os(iOS)
    Color(UIColor { $0.userInterfaceStyle == .dark ? .systemRed : UIColor(red: 0.74, green: 0.11, blue: 0.11, alpha: 1) })
    #else
    Color(NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .systemRed : NSColor(red: 0.74, green: 0.11, blue: 0.11, alpha: 1) })
    #endif
  }
}
