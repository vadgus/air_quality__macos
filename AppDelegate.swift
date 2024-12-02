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

    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.push()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.pop()
    }
}

struct APIResponse: Decodable {
    let data: DataSection

    struct DataSection: Decodable {
        let aqi: Int
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, CLLocationManagerDelegate {
    var statusItem: NSStatusItem?
    var cancellable: AnyCancellable?
    var timer: Timer?
    var isUpdating = false

    var locationManager = CLLocationManager()
    var lastKnownCoordinates: CLLocationCoordinate2D?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let statusButton = statusItem?.button {
            statusButton.title = "."
            statusButton.action = #selector(updateOnClick)
            statusButton.target = self
            fetchDataAndUpdateStatusBar()
            startPolling()
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu

        setupLocationManager()
    }

    func setupLocationManager() {
        locationManager.delegate = self

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
        Please enable location permissions in System Preferences > Security & Privacy > Location Services.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func handleLocationAuthorizationStatus(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways:
            locationManager.startUpdatingLocation()
        case .denied, .restricted:
            DispatchQueue.main.async {
                self.statusItem?.button?.title = "Location permission required"
            }
        case .notDetermined:
            break
        @unknown default:
            fatalError("Unhandled authorization status")
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        handleLocationAuthorizationStatus(status)
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        lastKnownCoordinates = location.coordinate
        saveUserSettings(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Failed to get location:", error.localizedDescription)
    }

    @objc func updateOnClick() {
        let status = locationManager.authorizationStatus

        if status == .authorizedAlways {
            fetchDataAndUpdateStatusBar()
        } else {
            DispatchQueue.main.async {
                self.statusItem?.button?.title = "Location permission required"
            }
        }
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(self)
    }

    @objc func openSettings() {
        let alert = NSAlert()
        alert.messageText = "Settings"
        alert.informativeText = "Enter your API token. To get a token, register at the following link:"

        let linkLabel = ClickableLinkTextField()
        linkLabel.isEditable = false
        linkLabel.isBordered = false
        linkLabel.backgroundColor = .clear
        linkLabel.allowsEditingTextAttributes = true
        linkLabel.isSelectable = true

        let attributedString = NSMutableAttributedString(string: "https://aqicn.org/data-platform/token/")
        attributedString.addAttribute(.link, value: "https://aqicn.org/data-platform/token/", range: NSRange(location: 0, length: attributedString.length))
        attributedString.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: NSRange(location: 0, length: attributedString.length))
        linkLabel.attributedStringValue = attributedString
        linkLabel.translatesAutoresizingMaskIntoConstraints = false

        let tokenField = NSTextField(string: loadUserSettings().token ?? "")
        tokenField.placeholderString = "Token"
        tokenField.translatesAutoresizingMaskIntoConstraints = false

        let containerView = NSView()
        containerView.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(linkLabel)
        containerView.addSubview(tokenField)

        NSLayoutConstraint.activate([
            linkLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 10),
            linkLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 10),
            linkLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -10),
            tokenField.topAnchor.constraint(equalTo: linkLabel.bottomAnchor, constant: 10),
            tokenField.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 10),
            tokenField.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -10),
            tokenField.heightAnchor.constraint(equalToConstant: 24),
            tokenField.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -10)
        ])

        containerView.setFrameSize(NSSize(width: 255, height: 50))
        alert.accessoryView = containerView

        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            saveUserSettings(token: tokenField.stringValue)
            fetchDataAndUpdateStatusBar()
        }
    }

    func fetchDataAndUpdateStatusBar() {
        guard !isUpdating else { return }
        isUpdating = true
        DispatchQueue.main.async {
            self.statusItem?.button?.title = "."
        }

        let userSettings = loadUserSettings()
        guard let token = userSettings.token, !token.isEmpty else {
            DispatchQueue.main.async {
                self.statusItem?.button?.title = "Invalid config"
            }
            isUpdating = false
            return
        }

        let coordinates = lastKnownCoordinates ?? CLLocationCoordinate2D(
            latitude: userSettings.latitude ?? 0.0,
            longitude: userSettings.longitude ?? 0.0
        )
        let apiURLString = "https://api.waqi.info/feed/geo:\(coordinates.latitude);\(coordinates.longitude)/?token=\(token)"
        guard let apiURL = URL(string: apiURLString) else { return }

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.waitsForConnectivity = true
        let session = URLSession(configuration: sessionConfig)

        cancellable = session.dataTaskPublisher(for: apiURL)
            .tryMap { (data, response) -> Data in
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: APIResponse.self, decoder: JSONDecoder())
            .sink(receiveCompletion: { [weak self] completion in
                DispatchQueue.main.async {
                    self?.isUpdating = false
                }
                if case let .failure(error) = completion {
                    DispatchQueue.main.async {
                        self?.statusItem?.button?.title = "Invalid config"
                    }
                    print("Error fetching data:", error.localizedDescription)
                }
            }, receiveValue: { [weak self] response in
                DispatchQueue.main.async {
                    self?.statusItem?.button?.title = "\(response.data.aqi)"
                    self?.isUpdating = false
                }
            })
    }

    func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.fetchDataAndUpdateStatusBar()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        cancellable?.cancel()
    }

    func saveUserSettings(latitude: Double? = nil, longitude: Double? = nil, token: String? = nil) {
        if let latitude = latitude { UserDefaults.standard.set(latitude, forKey: "latitude") }
        if let longitude = longitude { UserDefaults.standard.set(longitude, forKey: "longitude") }
        if let token = token { UserDefaults.standard.set(token, forKey: "token") }
    }

    func loadUserSettings() -> (latitude: Double?, longitude: Double?, token: String?) {
        let latitude = UserDefaults.standard.double(forKey: "latitude")
        let longitude = UserDefaults.standard.double(forKey: "longitude")
        let token = UserDefaults.standard.string(forKey: "token")
        return (latitude == 0 ? nil : latitude, longitude == 0 ? nil : longitude, token)
    }
}
