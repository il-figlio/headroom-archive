import Testing
@testable import HeadroomCore

private let gib: Double = 1_073_741_824
private func bytes(gb: Double) -> UInt64 { UInt64((gb * gib).rounded()) }

@Test func byteFormatStaysInGigabytesBelowOneTerabyte() {
    #expect(MemoryFormat.string(bytes(gb: 999.9)) == "999.90 GB")
    #expect(MemoryFormat.compact(bytes(gb: 999.9)) == "999.9 GB")
    #expect(MemoryFormat.string(bytes(gb: 12.8)) == "12.80 GB")
    #expect(MemoryFormat.compact(bytes(gb: 64)) == "64.0 GB")
    #expect(MemoryFormat.string(492 * 1_048_576) == "492 MB")
}

@Test func byteFormatSwitchesToTerabytesAtOneTerabyte() {
    #expect(MemoryFormat.string(bytes(gb: 1000)) == "1000.00 GB")
    #expect(MemoryFormat.compact(bytes(gb: 1023.9)) == "1023.9 GB")
    #expect(MemoryFormat.string(bytes(gb: 1024)) == "1.00 TB")
    #expect(MemoryFormat.compact(bytes(gb: 1024)) == "1.00 TB")
    #expect(MemoryFormat.string(bytes(gb: 2048)) == "2.00 TB")
    #expect(MemoryFormat.compact(bytes(gb: 2048)) == "2.00 TB")
    #expect(MemoryFormat.string(bytes(gb: 1286.4)) == "1.26 TB")
    #expect(MemoryFormat.compact(bytes(gb: 1286.4)) == "1.26 TB")
    #expect(MemoryFormat.string(bytes(gb: 12 * 1024)) == "12.0 TB")
    #expect(MemoryFormat.compact(bytes(gb: 12 * 1024)) == "12.0 TB")
}

/// Values that would round up to "1024.0 GB" or "10.00 TB" take the next unit,
/// and a TB value never reads under "1.00 TB".
@Test func byteFormatNeverPrintsSubOneTerabyteOrTenPointZeroZeroTerabytes() {
    #expect(MemoryFormat.compact(bytes(gb: 1023.97)) == "1.00 TB")
    #expect(MemoryFormat.string(bytes(gb: 1023.97)) == "1023.97 GB")
    #expect(MemoryFormat.string(bytes(gb: 10 * 1024 - 1)) == "10.0 TB")
}
