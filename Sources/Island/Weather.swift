import Foundation
import CoreLocation
import Observation

/// Weather from Open-Meteo (no key). Location from CoreLocation, or a city typed
/// in Settings (geocoded with Open-Meteo geocoding).
@Observable @MainActor
final class Weather: NSObject, CLLocationManagerDelegate {
    static let shared = Weather()

    var temperature: Double?
    var high: Double?
    var low: Double?
    var code: Int = 0
    var isDay = true
    var city = ""
    var status = "Loading…"
    var locationDenied = false

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var coord: CLLocationCoordinate2D?
    @ObservationIgnored private var lastFetch = Date.distantPast

    func start() {
        if Env.noPermissions {
            city = "Demo City"; temperature = 16; high = 21; low = 14; code = 2; isDay = true; status = ""
            return
        }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        refreshLocation()
        timer?.invalidate()
        let t = Timer(timeInterval: 30 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { Weather.shared.refreshLocation() }
        }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refreshLocation() {
        guard !Env.noPermissions else { return }
        let p = AppSettings.shared.prefs
        if p.useCurrentLocation {
            switch manager.authorizationStatus {
            case .notDetermined:
                status = "Waiting for location permission"
                manager.requestWhenInUseAuthorization()
                return
            case .authorized, .authorizedAlways:
                locationDenied = false
                manager.requestLocation()
                return
            default:
                locationDenied = true
            }
        }
        if let lat = p.manualLat, let lon = p.manualLon {
            city = p.manualCity
            fetch(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        } else {
            status = locationDenied ? "Set a city in Settings" : "No location"
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in
            if m.authorizationStatus != .notDetermined { self.refreshLocation() }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        Task { @MainActor in
            self.coord = loc.coordinate
            self.fetch(loc.coordinate)
            if let pm = try? await CLGeocoder().reverseGeocodeLocation(loc).first {
                self.city = pm.locality ?? pm.subAdministrativeArea ?? pm.administrativeArea ?? ""
            }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            let p = AppSettings.shared.prefs
            if let lat = p.manualLat, let lon = p.manualLon {
                self.city = p.manualCity
                self.fetch(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            } else if let c = self.coord {
                self.fetch(c)
            } else {
                self.status = "Location unavailable"
            }
        }
    }

    func fetch(_ c: CLLocationCoordinate2D) {
        let unit = AppSettings.shared.prefs.tempUnit == .fahrenheit ? "fahrenheit" : "celsius"
        let s = "https://api.open-meteo.com/v1/forecast?latitude=\(c.latitude)&longitude=\(c.longitude)"
            + "&current=temperature_2m,weather_code,is_day&daily=temperature_2m_max,temperature_2m_min"
            + "&timezone=auto&forecast_days=1&temperature_unit=\(unit)"
        guard let url = URL(string: s) else { return }
        lastFetch = Date()
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                if self.temperature == nil { self.status = "Offline" }
                return
            }
            let cur = obj["current"] as? [String: Any] ?? [:]
            let daily = obj["daily"] as? [String: Any] ?? [:]
            self.temperature = cur["temperature_2m"] as? Double
            self.code = cur["weather_code"] as? Int ?? 0
            self.isDay = (cur["is_day"] as? Int ?? 1) == 1
            self.high = (daily["temperature_2m_max"] as? [Double])?.first
            self.low = (daily["temperature_2m_min"] as? [Double])?.first
            self.status = ""
        }
    }

    /// Geocode a city name with Open-Meteo and store it as the manual location.
    func setCity(_ name: String) async -> Bool {
        let q = name.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, var comps = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search") else { return false }
        comps.queryItems = [URLQueryItem(name: "name", value: q), URLQueryItem(name: "count", value: "1")]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (obj["results"] as? [[String: Any]])?.first,
              let lat = first["latitude"] as? Double, let lon = first["longitude"] as? Double else { return false }
        var p = AppSettings.shared.prefs
        p.manualCity = first["name"] as? String ?? q
        p.manualLat = lat
        p.manualLon = lon
        AppSettings.shared.prefs = p
        refreshLocation()
        return true
    }

    var symbol: String {
        switch code {
        case 0: return isDay ? "sun.max" : "moon.stars"
        case 1, 2: return isDay ? "cloud.sun" : "cloud.moon"
        case 3: return "cloud"
        case 45, 48: return "cloud.fog"
        case 51...57: return "cloud.drizzle"
        case 61...67, 80...82: return "cloud.rain"
        case 71...77, 85, 86: return "cloud.snow"
        case 95...99: return "cloud.bolt.rain"
        default: return "cloud"
        }
    }

    var condition: String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly Clear"
        case 2: return "Partly Cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Fog"
        case 51...57: return "Drizzle"
        case 61...67: return "Rain"
        case 80...82: return "Showers"
        case 71...77, 85, 86: return "Snow"
        case 95...99: return "Thunderstorm"
        default: return ""
        }
    }
}
