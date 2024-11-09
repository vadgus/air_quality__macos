import AppKit
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var cancellable: AnyCancellable?
    var timer: Timer?

    // Set API URL here or fetch it from a config.
    let apiURL = URL(string: "https://api.waqi.info/feed/limassol/?token=123")!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let statusButton = statusItem?.button {
            statusButton.title = "." // Initial placeholder text
            statusButton.action = #selector(updateOnClick) // Add click action
            statusButton.target = self
            fetchDataAndUpdateStatusBar() // Initial data fetch on launch
            startPolling() // Set up periodic updates
        }
        
        // Set up right-click (or two-finger click) menu
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc func updateOnClick() {
        fetchDataAndUpdateStatusBar()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(self)
    }

    func fetchDataAndUpdateStatusBar() {
        // Use apiURL directly since it is non-optional
        let url = apiURL
        
        cancellable = URLSession.shared.dataTaskPublisher(for: url)
            .map { $0.data }
            .decode(type: YourAPIResponse.self, decoder: JSONDecoder())
            .sink(receiveCompletion: { completion in
                if case let .failure(error) = completion {
                    print("Error fetching data:", error)
                }
            }, receiveValue: { [weak self] response in
                DispatchQueue.main.async {
                    let value = response.data.aqi
                    self?.statusItem?.button?.title = "\(value)"
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
}

// Define the structure of your API response
struct YourAPIResponse: Codable {
    struct Data: Codable {
        let aqi: Int
    }
    let status: String
    let data: Data
}
