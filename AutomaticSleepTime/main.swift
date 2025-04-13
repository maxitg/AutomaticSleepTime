import CoreLocation
import EventKit
import Foundation
import Solar

func authorizeCalendar() {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .notDetermined:
        EKEventStore().requestAccess(
            to: .event,
            completion: { (granted: Bool, error: Error?) in
                if !granted {
                    print(error?.localizedDescription ?? "Could not get Calendar access")
                }
            }
        )
    case .authorized: break
    case .denied:
        print("User denied Calendar access. Cannot determine location or write events")
    case .restricted:
        print("Access to Calendar is restricted. Cannot determine location or write events")
    @unknown default:
        print("Unknown error occured while accessing Calendar")
    }
}

struct LocationData {
    var location: EKStructuredLocation
    // 2 dunovs -- brush teeth
    // 2 dunovs -- get a drink
    // 4 dunovs -- get to the trailhead
    var wakeUpOffset = TimeInterval(-8 * dunov)
}

func getUserLocation(forNightAfter date: Date) -> LocationData? {
    let calendars = eventStore.calendars(for: .event)
    var userCalendars: [EKCalendar] = []
    for calendar in calendars {
        if !calendar.isImmutable, !calendar.isSubscribed, calendar.allowsContentModifications {
            userCalendars.append(calendar)
        }
    }
    let predicate = eventStore.predicateForEvents(withStart: date, end: date, calendars: userCalendars)
    let events = eventStore.events(matching: predicate)
    var shortestDuration = TimeInterval.greatestFiniteMagnitude
    var shortestEvent: EKEvent?
    var wakeUpOffset: TimeInterval?
    for event in events {
        if !event.isAllDay {
            continue
        }
        if event.endDate.timeIntervalSince(date) <= TimeInterval(24 * 3600) { continue }
        if event.title == "Stay: nil" {
            return nil
        }
        let wakeUpOffsetDunovPrefix = "WakeUpOffsetDunov: "
        if event.title.hasPrefix(wakeUpOffsetDunovPrefix) {
            if let value = Int(
                event.title.suffix(
                    from: event.title.index(
                        event.title.startIndex,
                        offsetBy: wakeUpOffsetDunovPrefix.count
                    )
                ),
                radix: 16
            ) {
                wakeUpOffset = Double(value) * dunov
            }
        }
        guard event.structuredLocation?.geoLocation?.coordinate != nil else { continue }
        let duration = event.endDate.timeIntervalSince(event.startDate)
        if duration < shortestDuration {
            shortestDuration = duration
            shortestEvent = event
        }
    }
    guard shortestEvent != nil else { return nil }
    var locationData = LocationData(location: shortestEvent!.structuredLocation!)
    if wakeUpOffset != nil {
        locationData.wakeUpOffset = wakeUpOffset!
    }
    return locationData
}

let dunov = TimeInterval(308)
let trenov = 16 * dunov
let earthDay = TimeInterval(24 * 3600)
let sleepEventName = "Sleep"

func sleepInterval(
    forNightAfter date: Date,
    atLocation location: CLLocationCoordinate2D,
    withWakeUpOffset wakeUpOffset: TimeInterval
) -> DateInterval? {
    guard let sunrise = Solar(for: date.addingTimeInterval(earthDay), coordinate: location)?.civilSunrise else {
        return nil
    }
    // 68 dunovs -- sleep (should be between 50 and 70)
    let sleepDuration = 0x68 * dunov
    return DateInterval(start: sunrise.addingTimeInterval(-sleepDuration + wakeUpOffset), duration: sleepDuration)
}

func getBodyCalendar(_ eventStore: EKEventStore) -> EKCalendar? {
    let calendars = eventStore.calendars(for: .event)
    var bodyCalendar: EKCalendar?
    for calendar in calendars {
        if calendar.title == "Body" {
            bodyCalendar = calendar
        }
    }
    return bodyCalendar
}

func deleteOldSleepEvents(
    _ eventStore: EKEventStore,
    inCalendar calendar: EKCalendar,
    from startDate: Date,
    to endDate: Date
) {
    let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: [calendar])
    let allEvents = eventStore.events(matching: predicate)
    for event in allEvents {
        if event.title == sleepEventName {
            do {
                try eventStore.remove(event, span: .thisEvent)
            } catch {
                print("Could not remove an existing sleep event: ", error.localizedDescription)
            }
        }
    }
}

func createSleepEvent(_ eventStore: EKEventStore, inCalendar calendar: EKCalendar, forNightAfter date: Date) {
    guard let locationData = getUserLocation(forNightAfter: date) else {
        print("Could not find a location at", date)
        return
    }

    guard
        let interval = sleepInterval(
            forNightAfter: date,
            atLocation: locationData.location.geoLocation!.coordinate,
            withWakeUpOffset: locationData.wakeUpOffset
        )
    else {
        print("Could not find a sleep interval at", date)
        return
    }

    let sleepEvent = EKEvent(eventStore: eventStore)
    sleepEvent.structuredLocation = locationData.location
    sleepEvent.isAllDay = false
    sleepEvent.startDate = interval.start
    sleepEvent.endDate = interval.end
    sleepEvent.availability = .busy
    sleepEvent.calendar = calendar
    sleepEvent.title = sleepEventName
    sleepEvent.alarms = [EKAlarm(relativeOffset: TimeInterval(-4 * dunov))]
    do {
        try eventStore.save(sleepEvent, span: .thisEvent, commit: true)
    } catch {
        print("Could not save an event:", error.localizedDescription)
    }
}

extension Date: Strideable {
    public func distance(to other: Date) -> TimeInterval {
        other.timeIntervalSinceReferenceDate - timeIntervalSinceReferenceDate
    }

    public func advanced(by n: TimeInterval) -> Date {
        self + n
    }
}

authorizeCalendar()
let eventStore = EKEventStore()

guard let bodyCalendar = getBodyCalendar(eventStore) else {
    print("Could not find Body calendar")
    exit(1)
}

let startDate = Date()
var endDate: Date = startDate.addingTimeInterval(earthDay)
if CommandLine.arguments.count > 1 {
    if let dayCount = Int(CommandLine.arguments[1], radix: 16) {
        endDate = Date().addingTimeInterval(Double(dayCount) * earthDay)
    }
}

deleteOldSleepEvents(eventStore, inCalendar: bodyCalendar, from: Date(), to: endDate)

for date in stride(from: Date(), to: endDate, by: TimeInterval(earthDay)) {
    print(date, "...")
    createSleepEvent(eventStore, inCalendar: bodyCalendar, forNightAfter: date)
}
