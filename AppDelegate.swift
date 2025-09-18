import AppKit
import Combine
import CoreLocation

class ClickableLinkTextField: NSTextField {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        self.addTrackingArea(NSTrackingArea(
            rect: self.bounds,
            options: [.activeAlways, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { NSCursor.pointingHand.push() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.pop() }
}

struct OpenMeteoAQIResponse: Decodable {
    struct Hourly: Decodable {
        let time: [String]
        let us_aqi: [Double]?
    }
    let hourly: Hourly
}

class AppDelegate: NSObject, NSApplicationDelegate, CLLocationManagerDelegate {
    var statusItem: NSStatusItem?
    var cancellable: AnyCancellable?
    var timer: Timer?
    var isUpdating = false

    var locationManager = CLLocationManager()
    var lastKnownCoordinates: CLLocationCoordinate2D?
    var previousLocation: CLLocation?
    var intervalMenuRef: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let statusButton = statusItem?.button {
            statusButton.title = "…"
            statusButton.action = #selector(updateOnClick)
            statusButton.target = self
            fetchDataAndUpdateStatusBar()
            startPolling()
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Update", action: #selector(updateLocation), keyEquivalent: ""))
        let intervalMenu = NSMenu(title: "Update Interval")
        let intervals: [(String, TimeInterval)] = [
            ("1m", 60), ("5m", 300), ("10m", 600), ("15m", 900), ("30m", 1800),
            ("1h", 3600), ("3h", 10800), ("6h", 21600), ("12h", 43200), ("24h", 86400)
        ]
        for (label, interval) in intervals {
            let item = NSMenuItem(title: label, action: #selector(setInterval(_:)), keyEquivalent: "")
            item.tag = Int(interval)
            item.state = interval == 3600 ? .on : .off
            intervalMenu.addItem(item)
        }
        self.intervalMenuRef = intervalMenu
        let intervalItem = NSMenuItem(title: "Interval", action: nil, keyEquivalent: "")
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Source", action: #selector(openDataSourceInfo), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu

        setupLocationManager()
    }

    func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters

        let status = locationManager.authorizationStatus
        handleLocationAuthorizationStatus(status)

        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else if status == .denied || status == .restricted {
            notifyPermissionRequired()
        }
    }

    func notifyPermissionRequired() {
        let alert = NSAlert()
        alert.messageText = "Location Permission Required"
        alert.informativeText = """
        This app requires location access to fetch air quality data.
        Please enable location permissions in System Settings → Privacy & Security → Location Services.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func handleLocationAuthorizationStatus(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorized, .authorizedAlways:
            locationManager.requestLocation()
        case .denied, .restricted:
            DispatchQueue.main.async { self.statusItem?.button?.title = "AirQuality: location permission required" }
            notifyPermissionRequired()
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        @unknown default:
            DispatchQueue.main.async { self.statusItem?.button?.title = "Error" }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        handleLocationAuthorizationStatus(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        if let prevLoc = previousLocation {
            let distance = location.distance(from: prevLoc)
            if distance < 100 { return }
        }
        previousLocation = location
        lastKnownCoordinates = location.coordinate
        saveUserSettings(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        fetchDataAndUpdateStatusBar()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Failed to get location:", error.localizedDescription)
    }

    @objc func updateOnClick() {
        let status = locationManager.authorizationStatus
        if status == .authorized || status == .authorizedAlways {
            fetchDataAndUpdateStatusBar()
        } else {
            DispatchQueue.main.async { self.statusItem?.button?.title = "Location?" }
        }
    }

    @objc func quitApp() { NSApplication.shared.terminate(self) }

    @objc func openDataSourceInfo() {
        let alert = NSAlert()
        alert.messageText = "Data Source"
        alert.informativeText = "US AQI data is fetched from Open-Meteo Air Quality API."
        alert.alertStyle = .informational

        let linkLabel = ClickableLinkTextField()
        linkLabel.isEditable = false
        linkLabel.isBordered = false
        linkLabel.backgroundColor = .clear
        linkLabel.allowsEditingTextAttributes = true
        linkLabel.isSelectable = true

        let urlString = "https://open-meteo.com/en/docs/air-quality-api"
        let attributed = NSMutableAttributedString(string: urlString)
        attributed.addAttribute(.link, value: urlString, range: NSRange(location: 0, length: attributed.length))
        attributed.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: NSRange(location: 0, length: attributed.length))
        linkLabel.attributedStringValue = attributed
        linkLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(linkLabel)
        NSLayoutConstraint.activate([
            linkLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            linkLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            linkLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            linkLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10)
        ])
        container.setFrameSize(NSSize(width: 360, height: 28))
        alert.accessoryView = container

        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func fetchDataAndUpdateStatusBar() {
        guard !isUpdating else { return }
        isUpdating = true

        let settings = loadUserSettings()
        let coord = lastKnownCoordinates ?? CLLocationCoordinate2D(
            latitude: settings.latitude ?? 0.0,
            longitude: settings.longitude ?? 0.0
        )

        if coord.latitude == 0.0 && coord.longitude == 0.0 {
            locationManager.requestLocation()
            DispatchQueue.main.async { self.statusItem?.button?.title = "…" }
            isUpdating = false
            return
        }

        var comps = URLComponents(string: "https://air-quality-api.open-meteo.com/v1/air-quality")!
        comps.queryItems = [
            .init(name: "latitude", value: "\(coord.latitude)"),
            .init(name: "longitude", value: "\(coord.longitude)"),
            .init(name: "hourly", value: "us_aqi"),
            .init(name: "timezone", value: "auto"),
            .init(name: "past_hours", value: "2"),
            .init(name: "forecast_hours", value: "2")
        ]
        guard let url = comps.url else {
            DispatchQueue.main.async { self.statusItem?.button?.title = "N/A" }
            isUpdating = false
            return
        }

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.waitsForConnectivity = true
        let session = URLSession(configuration: sessionConfig)

        cancellable = session.dataTaskPublisher(for: url)
            .tryMap { (data, response) -> Data in
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: OpenMeteoAQIResponse.self, decoder: JSONDecoder())
            .sink(receiveCompletion: { [weak self] completion in
                DispatchQueue.main.async { self?.isUpdating = false }
                if case let .failure(error) = completion {
                    DispatchQueue.main.async { self?.statusItem?.button?.title = "N/A" }
                    print("Error fetching AQI:", error.localizedDescription)
                }
            }, receiveValue: { [weak self] response in
                guard let self = self else { return }
                let (aqi, timeStr) = self.currentAQI(from: response)
                DispatchQueue.main.async {
                    if let aqi = aqi {
                        self.statusItem?.button?.title = "\(Int(round(aqi)))"
                        self.statusItem?.button?.toolTip = "US AQI • \(timeStr ?? "")"
                    } else {
                        self.statusItem?.button?.title = "N/A"
                        self.statusItem?.button?.toolTip = "No AQI"
                    }
                    self.isUpdating = false
                }
            })
    }

    private func currentAQI(from resp: OpenMeteoAQIResponse) -> (Double?, String?) {
        let times = resp.hourly.time
        guard let aqiArray = resp.hourly.us_aqi, !times.isEmpty, !aqiArray.isEmpty else {
            return (nil, nil)
        }

        let parsedDates: [Date] = times.compactMap { Self.parseOpenMeteoDate($0) }
        guard !parsedDates.isEmpty else { return (aqiArray.last, times.last) }

        let now = Date()
        var bestIndex = 0
        for (i, t) in parsedDates.enumerated() {
            if t <= now { bestIndex = i } else { break }
        }
        bestIndex = max(0, min(bestIndex, aqiArray.count - 1))
        let aqi = aqiArray[bestIndex]
        let stamp = times[bestIndex]
        return (aqi, stamp)
    }

    private static func parseOpenMeteoDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withColonSeparatorInTime, .withColonSeparatorInTimeZone]
        if let d = iso.date(from: s) { return d }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return df.date(from: s)
    }

    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.fetchDataAndUpdateStatusBar()
        }
    }

    @objc func setInterval(_ sender: NSMenuItem) {
        intervalMenuRef?.items.forEach { $0.state = .off }
        sender.state = .on
        let interval = TimeInterval(sender.tag)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.fetchDataAndUpdateStatusBar()
        }
        updateLocation()
        fetchDataAndUpdateStatusBar()
    }

    @objc func updateLocation() { locationManager.requestLocation() }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        cancellable?.cancel()
    }

    func saveUserSettings(latitude: Double? = nil, longitude: Double? = nil) {
        if let latitude = latitude { UserDefaults.standard.set(latitude, forKey: "latitude") }
        if let longitude = longitude { UserDefaults.standard.set(longitude, forKey: "longitude") }
    }

    func loadUserSettings() -> (latitude: Double?, longitude: Double?) {
        let lat = UserDefaults.standard.object(forKey: "latitude") as? Double
        let lon = UserDefaults.standard.object(forKey: "longitude") as? Double
        return (lat, lon)
    }
}
