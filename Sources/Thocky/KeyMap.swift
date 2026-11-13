import CoreGraphics
import ThockAudio

/// Maps a hardware key code onto the key groups the sound packs record
/// (generic, return, space, backspace), plus a few display names for the UI.
enum KeyMap {
    static let generic = Int(KS_GROUP_GENERIC)
    static let enter = Int(KS_GROUP_ENTER)
    static let space = Int(KS_GROUP_SPACE)
    static let backspace = Int(KS_GROUP_BACKSPACE)

    static func group(for keyCode: CGKeyCode) -> Int {
        switch Int(keyCode) {
        case 36, 76:  return enter        // return, numpad enter
        case 49:      return space
        case 51:      return backspace    // delete
        default:      return generic
        }
    }

    static func name(for keyCode: CGKeyCode) -> String {
        switch Int(keyCode) {
        case 36, 76:  return "Return"
        case 49:      return "Space"
        case 51:      return "Delete"
        case 48:      return "Tab"
        case 53:      return "Escape"
        case 117:     return "Fwd Delete"
        case 123:     return "Left"
        case 124:     return "Right"
        case 125:     return "Down"
        case 126:     return "Up"
        default:      return "Key \(keyCode)"
        }
    }
}
