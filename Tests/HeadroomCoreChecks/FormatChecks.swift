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

@Test func compactFormatUsesMegabytesBelowOneGigabyte() {
    #expect(MemoryFormat.compact(bytes(gb: 0.3)) == "307 MB")
    #expect(MemoryFormat.compact(bytes(gb: 0.94)) == "963 MB")
    #expect(MemoryFormat.compact(bytes(gb: 0.96)) == "1.0 GB")
    #expect(MemoryFormat.compact(0) == "0 MB")
}

@Test func dailyRatesPickTheirOwnUnit() {
    #expect(MemoryFormat.perDay(gb: 0.2) == "205 MB/day")
    #expect(MemoryFormat.perDay(gb: 1.6) == "1.6 GB/day")
    #expect(MemoryFormat.perDay(gb: 1228.8) == "1.20 TB/day")
}

@Test func chartAxisUnitFollowsTheLargestValue() {
    #expect(ByteAxis.fitting(maxGB: 1286.4) == ByteAxis(unit: "TB", scale: 1.0 / 1024))
    #expect(ByteAxis.fitting(maxGB: 98.4).unit == "GB")
    #expect(ByteAxis.fitting(maxGB: 0.4).unit == "MB")
    #expect(ByteAxis.fitting(maxGB: 0).unit == "GB")
}

