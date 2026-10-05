import CoreAudio
import Testing
@testable import Yafie

struct TunerInputTests {
    private let builtIn = TunerInput(id: "BuiltInMicrophoneDevice", name: "MacBook Air Microphone",
                                     transport: kAudioDeviceTransportTypeBuiltIn, isDefault: false)

    private func input(_ name: String, _ transport: UInt32, isDefault: Bool = false) -> TunerInput {
        TunerInput(id: name, name: name, transport: transport, isDefault: isDefault)
    }

    @Test func usesTheDefaultInputWhenItsSafe() {
        let interface = input("Scarlett 2i2", kAudioDeviceTransportTypeUSB, isDefault: true)
        #expect(TunerInput.choose(from: [builtIn, interface]) == interface)
    }

    @Test(arguments: [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
                      kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
                      kAudioDeviceTransportTypeAutoAggregate, kAudioDeviceTransportTypeAirPlay,
                      kAudioDeviceTransportTypeUnknown])
    func neverOpensABluetoothOrVirtualInput(transport: UInt32) {
        let unsafe = input("Headset or virtual", transport, isDefault: true)
        #expect(TunerInput.choose(from: [unsafe, builtIn]) == builtIn)
        #expect(TunerInput.choose(from: [unsafe]) == nil)
    }

    @Test func fallsBackToTheMacsOwnMicrophoneFirst() {
        let headset = input("WH202A", kAudioDeviceTransportTypeBluetooth, isDefault: true)
        let interface = input("Scarlett 2i2", kAudioDeviceTransportTypeUSB)
        #expect(TunerInput.choose(from: [headset, interface, builtIn]) == builtIn)
    }

    @Test func withoutABuiltInMicrophoneUsesAnyWiredOne() {
        let headset = input("WH202A", kAudioDeviceTransportTypeBluetooth, isDefault: true)
        let interface = input("Scarlett 2i2", kAudioDeviceTransportTypeUSB)
        #expect(TunerInput.choose(from: [headset, interface]) == interface)
    }

    @Test func nothingToChooseFrom() {
        #expect(TunerInput.choose(from: []) == nil)
    }
}
