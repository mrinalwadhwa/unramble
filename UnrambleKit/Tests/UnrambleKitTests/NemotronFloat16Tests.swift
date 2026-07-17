import Testing
@testable import UnrambleKit

@Suite("Nemotron float16 conversion")
struct NemotronFloat16Tests {
    @Test("decodes representative IEEE-754 half values")
    func representativeValues() {
        let cases: [(UInt16, UInt32)] = [
            (0x0000, 0x0000_0000), // Positive zero
            (0x8000, 0x8000_0000), // Negative zero
            (0x0001, 0x3380_0000), // Smallest subnormal
            (0x0400, 0x3880_0000), // Smallest normal
            (0x3c00, 0x3f80_0000), // 1.0
            (0xc000, 0xc000_0000), // -2.0
            (0x7bff, 0x477f_e000), // Largest finite value
            (0x7c00, 0x7f80_0000), // Positive infinity
            (0xfc00, 0xff80_0000), // Negative infinity
        ]

        for (halfBits, expectedFloatBits) in cases {
            #expect(
                NemotronEngine.float16ToFloat32(halfBits).bitPattern
                    == expectedFloatBits
            )
        }
    }

    @Test("preserves NaN values")
    func nan() {
        #expect(NemotronEngine.float16ToFloat32(0x7e00).isNaN)
        #expect(NemotronEngine.float16ToFloat32(0xfe00).isNaN)
    }
}
