import LeanTypeDesign
import SwiftUI

extension EnvironmentValues {
    /// The active Soft Pebble theme. The companion app wears the same theme the user picked
    /// for their keyboard, so the two always feel like one product.
    @Entry var pebbleTheme: Theme = ThemeCatalog.cloud
}

extension Theme {
    var accent: Color { accentKey.fill.color }
    var onAccent: Color { accentKey.label.color }
    var ink: Color { letterKey.label.color }
    var subtleInk: Color { secondaryLabel.color }
    var surface: Color { letterKey.fill.color }
    var surfaceRim: Color { letterKey.rim.color }
    var chip: Color { functionKey.fill.color }
    var chipInk: Color { functionKey.label.color }
    var shadow: Color { keyShadow.color }

    var backgroundGradient: LinearGradient {
        LinearGradient(colors: [backgroundTop.color, backgroundBottom.color], startPoint: .top, endPoint: .bottom)
    }

    var colorScheme: ColorScheme {
        appearance == .dark ? .dark : .light
    }
}
