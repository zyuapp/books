import SwiftUI

/// The app's animation curves. Bounce-free springs keep their velocity when a change interrupts them.
enum Motion {
    /// Library and reader cross-fading.
    static let screenFadeDuration: TimeInterval = 0.25
    static let screenFade = Animation.smooth(duration: screenFadeDuration)
    /// Panels, the sidebar and other surfaces that slide.
    static let panel = Animation.smooth(duration: 0.3)
    /// Small popups and full-screen controls.
    static let popup = Animation.smooth(duration: 0.22)
    static let hover = Animation.snappy(duration: 0.2)
}
