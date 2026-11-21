import CoreLocation
import TavernCore
import UIKit

/// What the phone lends the agents while it's connected: its location and battery. The host asks
/// Paul before each call (the approval card), and iOS asks once for location.
@MainActor
final class PhoneSensors: NSObject, CLLocationManagerDelegate {
    static let tools = ["phone_location", "phone_battery"]

    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLLocation, Error>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    func answer(_ tool: String, _ arguments: JSONValue) async throws -> JSONValue {
        switch tool {
        case "phone_location": return try await location()
        case "phone_battery": return battery()
        default: throw Failure(errorDescription: "The phone doesn't have \(tool).")
        }
    }

    private func battery() -> JSONValue {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel < 0 ? JSONValue.null : .number(Double(Int(device.batteryLevel * 100)))
        let state: String = switch device.batteryState {
        case .charging: "charging"
        case .full: "full"
        case .unplugged: "unplugged"
        default: "unknown"
        }
        return ["level": level, "state": .string(state), "lowPowerMode": .bool(ProcessInfo.processInfo.isLowPowerModeEnabled)]
    }

    private func location() async throws -> JSONValue {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            throw Failure(errorDescription: "Location is off for Tavern in the iPhone's Settings.")
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default: break
        }
        let found = try await withCheckedThrowingContinuation { done in
            waiting.append(done)
            if waiting.count == 1 { manager.requestLocation() }
        }
        var result: [String: JSONValue] = [
            "latitude": .number(found.coordinate.latitude),
            "longitude": .number(found.coordinate.longitude),
            "accuracyMeters": .number(found.horizontalAccuracy.rounded()),
            "at": .string(ISO8601DateFormatter().string(from: found.timestamp)),
        ]
        if let place = try? await CLGeocoder().reverseGeocodeLocation(found).first {
            result["place"] = .string([place.name, place.locality, place.administrativeArea, place.country].compactMap { $0 }.joined(separator: ", "))
        }
        return .object(result)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in self.finish(.success(last)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(.failure(Failure(errorDescription: "The phone couldn't find its location (\(error.localizedDescription))."))) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .denied, .restricted: self.finish(.failure(Failure(errorDescription: "Location is off for Tavern in the iPhone's Settings.")))
            case .authorizedWhenInUse, .authorizedAlways: if !self.waiting.isEmpty { manager.requestLocation() }
            default: break
            }
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        let all = waiting
        waiting = []
        for done in all { done.resume(with: result) }
    }
}
