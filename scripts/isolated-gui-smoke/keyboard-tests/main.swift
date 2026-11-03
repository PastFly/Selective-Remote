import Carbon.HIToolbox

let samples: [(Character, UInt16, Bool)] = [
    ("a", UInt16(kVK_ANSI_A), false), ("A", UInt16(kVK_ANSI_A), true),
    ("z", UInt16(kVK_ANSI_Z), false), ("-", UInt16(kVK_ANSI_Minus), false),
    (".", UInt16(kVK_ANSI_Period), false), ("0", UInt16(kVK_ANSI_0), false),
    ("9", UInt16(kVK_ANSI_9), false)
]
for (character, code, shift) in samples {
    guard let stroke = syntheticKeyStroke(character), stroke.code == code, stroke.shift == shift else {
        fatalError("bad mapping for \(character)")
    }
}
guard syntheticKeyStroke("🔑") == nil else { fatalError("unsupported input must fail closed") }
guard syntheticPortMatches("52,222", "52222"), syntheticPortMatches("522", "522"),
      !syntheticPortMatches("5,2222", "52222"), !syntheticPortMatches("-52,222", "52222"),
      !syntheticPortMatches("52,223", "52222") else { fatalError("bad synthetic port verification") }
print("KEYBOARD_MAP_TEST=PASS")
