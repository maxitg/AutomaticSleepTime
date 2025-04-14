import ArgumentParser
import EventKit

struct TimeOff: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Track your time off.",
        subcommands: [List.self],
        defaultSubcommand: List.self
    )
}

struct CommonOptions: ParsableArguments {
    @Option(name: .customLong("since"), help: "Start date in YYYY-MM-DD format.")
    var since: String = .init(Date().description.split(separator: " ").first!)

    @Option(name: .customLong("target-days-per-year"), help: "Target number of days off per year.")
    var targetDaysPerYear: Int = 18
}

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List taken time off.")

    @OptionGroup var options: CommonOptions

    func run() throws {
        let tracker = try TimeOffTracker(from: options.since, targetDaysPerYear: options.targetDaysPerYear)
        for event in tracker.ranges {
            print(event.description)
        }
        if tracker.ranges.count == 0 {
            print("No time off found")
        }

        let totalUsed = tracker.ranges.reduce(0) { $0 + $1.usedDays }
        print()
        print("Total used: \(totalUsed)")
        print("Budget: \(tracker.budgetDays)")
    }
}
