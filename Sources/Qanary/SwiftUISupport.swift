#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

@available(iOS 13.0, *)
public extension View {
    /// Names this view as a screen in the struggle report when it appears. SwiftUI has no view controllers of the
    /// app's own for the SDK to watch, so name the screens that matter:
    ///
    ///     CheckoutView().qanaryScreen("Checkout")
    func qanaryScreen(_ name: String) -> some View {
        onAppear { Qanary.screen(name) }
    }
}
#endif
