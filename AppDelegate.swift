import AppKit
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var cancellable: AnyCancellable?
    var timer: Timer?
    var isUpdating = false

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
    }

    @objc func updateOnClick() {
        fetchDataAndUpdateStatusBar()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(self)
    }

    @objc func openSettings() {
        let alert = NSAlert()
        alert.messageText = "Settings"
        alert.informativeText = "Enter your city and API token. To get a token, register at the following link:"

        let linkLabel = NSTextField()
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

        let spacerView = NSView()
        spacerView.translatesAutoresizingMaskIntoConstraints = false

        let cityField = NSTextField(string: loadUserSettings().city ?? "")
        cityField.placeholderString = "City"
        cityField.translatesAutoresizingMaskIntoConstraints = false

        let tokenField = NSTextField(string: loadUserSettings().token ?? "")
        tokenField.placeholderString = "Token"
        tokenField.translatesAutoresizingMaskIntoConstraints = false

        let containerView = NSView()
        containerView.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(linkLabel)
        containerView.addSubview(spacerView)
        containerView.addSubview(cityField)
        containerView.addSubview(tokenField)

        NSLayoutConstraint.activate([
            linkLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 10),
            linkLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 10),
            linkLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -10),
            spacerView.topAnchor.constraint(equalTo: linkLabel.bottomAnchor, constant: 5),
            spacerView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            spacerView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            spacerView.heightAnchor.constraint(equalToConstant: 10),
            cityField.topAnchor.constraint(equalTo: spacerView.bottomAnchor, constant: 10),
            cityField.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 10),
            cityField.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -10),
            cityField.heightAnchor.constraint(equalToConstant: 24),
            tokenField.topAnchor.constraint(equalTo: cityField.bottomAnchor, constant: 10),
            tokenField.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 10),
            tokenField.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -10),
            tokenField.heightAnchor.constraint(equalToConstant: 24),
            tokenField.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -10)
        ])

        containerView.setFrameSize(NSSize(width: 255, height: 110))
        alert.accessoryView = containerView

        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            saveUserSettings(city: cityField.stringValue, token: tokenField.stringValue)
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
        guard let city = userSettings.city, !city.isEmpty,
              let token = userSettings.token, !token.isEmpty,
              let apiURL = URL(string: "https://api.waqi.info/feed/\(city)/?token=\(token)") else {
            DispatchQueue.main.async {
                self.statusItem?.button?.title = "Invalid config"
            }
            isUpdating = false
            return
        }

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

    func saveUserSettings(city: String, token: String) {
        UserDefaults.standard.set(city, forKey: "city")
        UserDefaults.standard.set(token, forKey: "token")
    }

    func loadUserSettings() -> (city: String?, token: String?) {
        let city = UserDefaults.standard.string(forKey: "city")
        let token = UserDefaults.standard.string(forKey: "token")
        return (city, token)
    }
}

extension NSTextField {
    var maxLength: Int {
        get { return 0 }
        set {
            target = self
            action = #selector(limitTextLength)
        }
    }

    @objc private func limitTextLength() {
        guard let stringValue = self.stringValue as NSString? else { return }
        if stringValue.length > maxLength {
            self.stringValue = stringValue.substring(to: maxLength)
        }
    }
}

struct APIResponse: Codable {
    struct Data: Codable {
        let aqi: Int
    }
    let status: String
    let data: Data
}
