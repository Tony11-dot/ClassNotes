import Foundation

/// Where the app points people: the legal pages and how to reach support.
public enum ClassMateLinks {
    public static let legalHome = URL(string: "https://tony11-dot.github.io/classmate-legal/")!
    public static let privacy = URL(string: "https://tony11-dot.github.io/classmate-legal/privacy.html")!
    public static let accessibility = URL(string: "https://tony11-dot.github.io/classmate-legal/accessibility.html#classnotes")!
    public static let supportEmail = "support@classmateapp.org"
    public static let supportPhone = "+972525488441"
    public static var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return v
    }
}
