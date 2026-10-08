import Foundation

/// A write that didn't reach disk, in words a student can act on.
///
/// Every save in the editor used to be `try?`: a full disk meant the user kept
/// writing, saw everything on screen, and lost it all at the next launch
/// without a word. Whatever failed is still held — the editor's manifest, the
/// ink journal's staged bytes — and is retried, so the message can honestly
/// say the work is still there.
public struct SaveProblem: Equatable, Sendable {
    public var isOutOfSpace: Bool

    public init(isOutOfSpace: Bool) {
        self.isOutOfSpace = isOutOfSpace
    }

    public init(_ error: Error) {
        self.init(isOutOfSpace: Self.isOutOfSpace(error))
    }

    public var title: String {
        isOutOfSpace ? "Your iPad is out of storage" : "Couldn't save your latest changes"
    }

    public var message: String {
        isOutOfSpace
            ? "ClassNotes can't save new changes until there's room. Everything on screen is "
                + "still here. Free up some space and it will save on its own."
            : "Everything on screen is still here, and ClassNotes will keep trying to save it."
    }

    static func isOutOfSpace(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let error = current {
            if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError { return true }
            if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}
