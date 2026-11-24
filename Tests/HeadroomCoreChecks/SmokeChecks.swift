import Testing
@testable import HeadroomCore

@Test func quotaPolicyStaleWindowIsTwicePollInterval() {
    #expect(QuotaPolicy.staleAfter == 2 * QuotaPolicy.interval)
}
