import Testing

@testable import UnrambleKit

@Suite("Dictation mode availability")
struct DictationModeAvailabilityTests {

    @Test("Local mode falls back to cloud when on-device is unavailable")
    func localFallsBackWhenUnavailable() {
        #expect(
            DictationModeAvailability.resolveEffectiveMode(
                stored: .local, isLocalAvailable: false) == .cloud)
    }

    @Test("Local mode stays local when on-device is available")
    func localStaysWhenAvailable() {
        #expect(
            DictationModeAvailability.resolveEffectiveMode(
                stored: .local, isLocalAvailable: true) == .local)
    }

    @Test("Cloud mode stays cloud regardless of on-device availability")
    func cloudStaysCloud() {
        #expect(
            DictationModeAvailability.resolveEffectiveMode(
                stored: .cloud, isLocalAvailable: false) == .cloud)
        #expect(
            DictationModeAvailability.resolveEffectiveMode(
                stored: .cloud, isLocalAvailable: true) == .cloud)
    }

    @Test("Local availability follows on-device support")
    func localAvailabilityFollowsSupport() {
        #expect(
            DictationModeAvailability.isAvailable(
                for: .local, isLocalAvailable: true, isConfigured: false))
        #expect(
            !DictationModeAvailability.isAvailable(
                for: .local, isLocalAvailable: false, isConfigured: true))
    }

    @Test("Cloud availability follows configuration")
    func cloudAvailabilityFollowsConfiguration() {
        #expect(
            DictationModeAvailability.isAvailable(
                for: .cloud, isLocalAvailable: false, isConfigured: true))
        #expect(
            !DictationModeAvailability.isAvailable(
                for: .cloud, isLocalAvailable: true, isConfigured: false))
    }
}
