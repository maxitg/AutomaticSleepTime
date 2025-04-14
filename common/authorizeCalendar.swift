import EventKit

func authorizeCalendar(_ eventStore: EKEventStore) -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    var authorizationGranted = false
    let accessDeniedMessage = "User denied Calendar access"

    switch EKEventStore.authorizationStatus(for: .event) {
    case .notDetermined:
        eventStore.requestFullAccessToEvents { granted, error in
            if let error = error {
                print("Error requesting Calendar access: \(error.localizedDescription)")
            } else if !granted {
                print(accessDeniedMessage)
            }
            authorizationGranted = granted
            semaphore.signal()
        }
        semaphore.wait() // Wait until the user responds
    case .fullAccess:
        authorizationGranted = true
    case .writeOnly:
        print("Write-only access is insufficient, read access is required")
    case .denied:
        print(accessDeniedMessage)
    case .restricted:
        print("Access to Calendar is restricted")
    @unknown default:
        print("Unknown error occured while accessing Calendar")
    }

    return authorizationGranted
}
