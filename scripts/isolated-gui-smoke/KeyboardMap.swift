import Carbon.HIToolbox
import Foundation

func syntheticPortMatches(_ formatted: String, _ expected: String) -> Bool {
    formatted.range(of: "^[0-9]{1,3}(,[0-9]{3})*$", options: .regularExpression) != nil &&
        formatted.replacingOccurrences(of: ",", with: "") == expected
}

struct SyntheticKeyStroke {
    let code: UInt16
    let shift: Bool
}

func syntheticKeyStroke(_ character: Character) -> SyntheticKeyStroke? {
    guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return nil }
    let value = scalar.value
    let letters: [UInt16] = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E,
                             kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J,
                             kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O,
                             kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T,
                             kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y,
                             kVK_ANSI_Z].map(UInt16.init)
    let digits: [UInt16] = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                            kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9].map(UInt16.init)
    if (65...90).contains(value) { return .init(code: letters[Int(value - 65)], shift: true) }
    if (97...122).contains(value) { return .init(code: letters[Int(value - 97)], shift: false) }
    if (48...57).contains(value) { return .init(code: digits[Int(value - 48)], shift: false) }
    if value == 45 { return .init(code: UInt16(kVK_ANSI_Minus), shift: false) }
    if value == 46 { return .init(code: UInt16(kVK_ANSI_Period), shift: false) }
    return nil
}
