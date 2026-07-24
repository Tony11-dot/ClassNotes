#if canImport(SwiftUI)
import SwiftUI

extension ThemeColor {
    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

extension Color {
    public init(_ themeColor: ThemeColor) {
        self = themeColor.color
    }
}
#endif
