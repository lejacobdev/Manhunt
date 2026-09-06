import WidgetKit
import SwiftUI

@main
struct HuntingGameWidgetsBundle: WidgetBundle {
    var body: some Widget {
        // A Live Activity only ever appears on the Lock Screen/Dynamic Island while a match
        // is running — it's never listed in iOS's home-screen "Add Widget" gallery. The
        // home-screen widget lives in this bundle too, since that gallery pulls every
        // `Widget` a matching extension declares, not just the Live Activity kind.
        HuntingGameLiveActivity()
        HuntingGameHomeWidget()
    }
}
