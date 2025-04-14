import EventKit

let day = TimeInterval(24 * 3600)
let year = round(day * 365.25)
let maxCalendarLookupDuration = TimeInterval(4 * 365 * 24 * 3600)

enum DayOffType: Int {
    case weekend = 0
    case holiday = 1
    case sickLeave = 2
    case vacation = 3
}

struct DayOff {
    let date: Date
    var type: DayOffType

    init(date: Date, type: DayOffType) {
        self.date = date
        self.type = if Calendar(identifier: .gregorian).isDateInWeekend(date) {
            .weekend
        } else {
            type
        }
    }

    func upgraded(to newType: DayOffType) -> DayOff {
        var result = self
        if type.rawValue < newType.rawValue {
            result.type = newType
        }
        return result
    }
}

struct DayOffRange: CustomStringConvertible {
    let daysOff: [DayOff]
    let name: String?

    var totalDays: Int { daysOff.count }
    var usedDays: Int { daysOff.filter { [.sickLeave, .vacation].contains($0.type) }.count }

    var start: Date { daysOff.first!.date }
    var end: Date { daysOff.last!.date }

    init(daysOff: [DayOff], name: String? = nil) {
        self.daysOff = daysOff
        self.name = name
    }

    init(type: DayOffType, start: Date, end: Date, name: String?) {
        self.name = name

        var fixedStart = start
        while Calendar(identifier: .gregorian).isDateInWeekend(fixedStart.addingTimeInterval(-day)) {
            fixedStart = fixedStart.addingTimeInterval(-day)
        }

        var fixedEnd = end
        while Calendar(identifier: .gregorian).isDateInWeekend(fixedEnd.addingTimeInterval(day)) {
            fixedEnd = fixedEnd.addingTimeInterval(day)
        }

        daysOff = stride(from: fixedStart, through: fixedEnd, by: day).map {
            .init(date: $0, type: type)
        }
    }

    var description: String {
        var result = "[\(String(format: "%2d", usedDays))/\(String(format: "%2d", totalDays))]  \(datesDescription)"
        if let name {
            result += ": \(name)"
        }

        // If no leave was used (weekends or holidays only), print in gray
        if usedDays == 0 {
            return "\u{001B}[90m\(result)\u{001B}[0m"
        } else {
            return result
        }
    }

    private var datesDescription: String {
        if daysOff.count == 0 {
            return "none"
        } else if daysOff.count == 1 {
            return DayOffRange.dateString(start)
        } else {
            return "\(DayOffRange.dateString(start)) to \(DayOffRange.dateString(end))"
        }
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    func merge(_ other: DayOffRange) -> [DayOffRange] {
        if end.addingTimeInterval(day) < other.start {
            return [self, other]
        }

        if other.end.addingTimeInterval(day) < start {
            return [other, self]
        }

        let (first, second) = if start < other.start {
            (self, other)
        } else {
            (other, self)
        }

        var mergedDaysOff: [DayOff] = []
        var secondDaysOffIndex = 0
        for day in first.daysOff {
            if day.date < second.daysOff.first!.date {
                mergedDaysOff.append(day)
            } else if secondDaysOffIndex < second.daysOff.count {
                mergedDaysOff.append(day.upgraded(to: second.daysOff[secondDaysOffIndex].type))
                secondDaysOffIndex += 1
            }
        }

        for idx in secondDaysOffIndex ..< second.daysOff.count {
            mergedDaysOff.append(second.daysOff[idx])
        }

        let newName = daysOff.count >= other.daysOff.count ? name : other.name

        return [DayOffRange(daysOff: mergedDaysOff, name: newName)]
    }
}

struct DateFormatError: Error {}

class TimeOffTracker {
    let eventStore: EKEventStore
    let startDate: Date
    let targetDaysPerYear: Int

    convenience init(from startDateString: String, targetDaysPerYear: Int) throws {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        guard let startDate = dateFormatter.date(from: startDateString) else {
            throw DateFormatError()
        }
        self.init(from: startDate, targetDaysPerYear: targetDaysPerYear)
    }

    init(from startDate: Date, targetDaysPerYear: Int) {
        self.startDate = startDate
        self.targetDaysPerYear = targetDaysPerYear
        eventStore = EKEventStore()
        guard authorizeCalendar(eventStore) else { fatalError("Failed to authorize calendar access") }
    }

    lazy var ranges: [DayOffRange] = {
        var result: [DayOffRange] = []
        for event in allEvents(since: startDate, to: Date().addingTimeInterval(maxCalendarLookupDuration)) {
            if let parsed = parsedEvent(event) {
                guard let lastEvent = result.popLast() else {
                    result.append(parsed)
                    continue
                }
                result += lastEvent.merge(parsed)
            }
        }
        return result
    }()

    lazy var budgetDays: Int = {
        let yearsSinceStart = Float(Date().timeIntervalSince(startDate)) / Float(year)
        return max(0, Int(floor(yearsSinceStart * Float(targetDaysPerYear))))
    }()

    private func allEvents(since startDate: Date, to endDate: Date) -> [EKEvent] {
        var events: [EKEvent] = []
        for currentStart in stride(from: startDate, to: endDate, by: maxCalendarLookupDuration) {
            let predicate = eventStore.predicateForEvents(
                withStart: currentStart,
                end: min(currentStart + maxCalendarLookupDuration, endDate),
                calendars: userCalendars
            )
            events += eventStore.events(matching: predicate)
        }
        return events
    }

    private var userCalendars: [EKCalendar] {
        let calendars = eventStore.calendars(for: .event)
        var userCalendars: [EKCalendar] = []
        for calendar in calendars {
            if !calendar.isImmutable, !calendar.isSubscribed, calendar.allowsContentModifications {
                userCalendars.append(calendar)
            }
        }
        return userCalendars
    }

    private func parsedEvent(_ event: EKEvent) -> DayOffRange? {
        if !event.isAllDay { return nil }
        if event.title.starts(with: "Company Holiday: ") {
            let name = event.title.replacingOccurrences(of: "Company Holiday: ", with: "")
            return DayOffRange(
                type: .holiday,
                start: event.startDate,
                end: event.endDate,
                name: name
            )
        } else if event.title.starts(with: "Time Off") {
            var name: String?
            if event.title.starts(with: "Time Off: ") {
                name = event.title.replacingOccurrences(of: "Time Off: ", with: "")
            }
            return DayOffRange(type: .vacation, start: event.startDate, end: event.endDate, name: name)
        } else if event.title.starts(with: "Sick Leave") {
            var name: String?
            if event.title.starts(with: "Sick Leave: ") {
                name = event.title.replacingOccurrences(of: "Sick Leave: ", with: "")
            }
            return DayOffRange(type: .sickLeave, start: event.startDate, end: event.endDate, name: name)
        }
        return nil
    }
}
