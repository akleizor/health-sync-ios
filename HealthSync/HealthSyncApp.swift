// HealthSync: Apple Health -> the health-export-mcp cache files, on your own devices.
// Read-only. Writes .health-cache.json + .health-workouts-cache.json into a folder you pick
// once (iCloud Drive:~/Tools/health-data style), which your Mac syncs onward.
import SwiftUI
import HealthKit
import UniformTypeIdentifiers
import BackgroundTasks

// MARK: - Metric table (must mirror the cache the MCP server reads)

struct Spec {
    let id: HKQuantityTypeIdentifier
    let name: String
    let label: String        // what the selection screen shows; the cache keeps `name`
    let cat: String
    let unit: String
    let cumulative: Bool     // true: daily SUM (steps, energy); false: daily MEAN (HR, HRV)
}

let SPECS: [Spec] = [
    .init(id: .stepCount, name: "step_count", label: "Schritte", cat: "Aktivität", unit: "count", cumulative: true),
    .init(id: .distanceWalkingRunning, name: "walking_running_distance", label: "Strecke", cat: "Aktivität", unit: "km", cumulative: true),
    .init(id: .activeEnergyBurned, name: "active_energy", label: "Aktive Energie", cat: "Aktivität", unit: "kcal", cumulative: true),
    .init(id: .basalEnergyBurned, name: "basal_energy_burned", label: "Grundumsatz", cat: "Aktivität", unit: "kcal", cumulative: true),
    .init(id: .flightsClimbed, name: "flights_climbed", label: "Stockwerke", cat: "Aktivität", unit: "count", cumulative: true),
    .init(id: .appleExerciseTime, name: "exercise_time", label: "Trainingsminuten", cat: "Aktivität", unit: "min", cumulative: true),
    .init(id: .appleStandTime, name: "apple_stand_time", label: "Stehminuten", cat: "Aktivität", unit: "min", cumulative: true),
    .init(id: .dietaryWater, name: "dietary_water", label: "Wasser", cat: "Körper", unit: "L", cumulative: true),
    .init(id: .heartRate, name: "heart_rate", label: "Herzfrequenz", cat: "Herz", unit: "count/min", cumulative: false),
    .init(id: .restingHeartRate, name: "resting_heart_rate", label: "Ruhepuls", cat: "Herz", unit: "count/min", cumulative: false),
    .init(id: .walkingHeartRateAverage, name: "walking_heart_rate_average", label: "Gehpuls", cat: "Herz", unit: "count/min", cumulative: false),
    .init(id: .heartRateVariabilitySDNN, name: "heart_rate_variability", label: "HRV", cat: "Herz", unit: "ms", cumulative: false),
    .init(id: .respiratoryRate, name: "respiratory_rate", label: "Atemfrequenz", cat: "Vitalwerte", unit: "count/min", cumulative: false),
    .init(id: .oxygenSaturation, name: "blood_oxygen_saturation", label: "Sauerstoffsättigung", cat: "Vitalwerte", unit: "%", cumulative: false),
    .init(id: .bodyMass, name: "weight_body_mass", label: "Gewicht", cat: "Körper", unit: "kg", cumulative: false),
    .init(id: .bodyFatPercentage, name: "body_fat_percentage", label: "Körperfett", cat: "Körper", unit: "%", cumulative: false),
    .init(id: .vo2Max, name: "vo2_max", label: "VO₂max", cat: "Vitalwerte", unit: "mL/min/kg", cumulative: false),
    .init(id: .walkingSpeed, name: "walking_speed", label: "Gehgeschwindigkeit", cat: "Vitalwerte", unit: "km/hr", cumulative: false),
    .init(id: .appleSleepingWristTemperature, name: "apple_sleeping_wrist_temperature", label: "Handgelenktemperatur", cat: "Vitalwerte", unit: "degC", cumulative: false),
    .init(id: .appleSleepingBreathingDisturbances, name: "breathing_disturbances", label: "Atemstörungen", cat: "Vitalwerte", unit: "count", cumulative: false),
]

/// Which metrics the owner wants exported. Stored by name, so the table above can grow
/// without a migration; a missing key means everything, which is what older installs expect.
enum Selection {
    static let key = "export.selection"
    static let workouts = "workouts"

    /// Sleep and workouts are not quantity specs, but they are selectable the same way.
    static var all: [String] { SPECS.map(\.name) + [SLEEP_NAME, workouts] }

    static var names: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? all) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: key) }
    }

    static func specs(_ enabled: Set<String>) -> [Spec] {
        SPECS.filter { enabled.contains($0.name) }
    }
}

let LOOKBACK_DAYS = 730          // ponytail: one constant, ~2 years. Raise if you want deeper history.
let SLEEP_NAME = "sleep_analysis"
let REFRESH_ID = "com.alexlee.healthsync.refresh"
let BOOKMARK_KEY = "folderBookmark"

// MARK: - Export

enum ExportError: LocalizedError {
    case healthUnavailable, noFolder, writeFailed(String)
    var errorDescription: String? {
        switch self {
        case .healthUnavailable: return "Health data is not available on this device."
        case .noFolder: return "Choose an output folder first."
        case .writeFailed(let m): return m
        }
    }
}

struct ExportSummary {
    let metrics: Int
    let workouts: Int
    let sessions: Int
}

struct Exporter {
    let store = HKHealthStore()
    let cal = Calendar.current

    var readTypes: Set<HKObjectType> {
        var s = Set<HKObjectType>()
        for spec in SPECS {
            if let t = HKQuantityType.quantityType(forIdentifier: spec.id) { s.insert(t) }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { s.insert(sleep) }
        s.insert(HKObjectType.workoutType())
        return s
    }

    func authorize() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw ExportError.healthUnavailable }
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    @discardableResult
    func run(into folder: URL) async throws -> ExportSummary {
        let start = cal.startOfDay(for: cal.date(byAdding: .day, value: -LOOKBACK_DAYS, to: Date())!)
        var metrics: [String: Any] = [:]
        let enabled = Selection.names
        let chosen = Selection.specs(enabled)
        for spec in chosen {
            guard let type = HKQuantityType.quantityType(forIdentifier: spec.id) else { continue }
            let daily = try await dailyPoints(type: type, spec: spec, from: start)
            guard !daily.isEmpty else { continue }
            metrics[spec.name] = ["unit": spec.unit, "cumulative": spec.cumulative,
                                  "daily": daily.sorted { $0.d < $1.d }.map { ["d": $0.d, "v": $0.v] }]
        }
        let sleepData = enabled.contains(SLEEP_NAME) ? try await sleep(from: start) : nil
        if let sleepData, !sleepData.daily.isEmpty {
            metrics[SLEEP_NAME] = ["unit": "hr", "cumulative": true,
                                   "daily": sleepData.daily.sorted { $0.d < $1.d }.map { ["d": $0.d, "v": $0.v] }]
        }
        // same shape MetricBridge writes, so get_sleep_sessions works either way
        let sessions: [String: Any] = ["schema": 1,
                                       "writtenAt": ISO8601DateFormatter.local.string(from: Date()),
                                       "sessions": sleepData?.sessions ?? []]
        // requested vs written is the only way to see a PARTIAL read denial: HealthKit refuses
        // silently per type, so "I asked for 18 and got 9" is the difference between a healthy
        // phone without data and a permission the owner never granted.
        metrics["_meta"] = ["schema": 1, "app": "healthsync-ios",
                            "requested": chosen.count, "written": metrics.count,
                            "writtenAt": ISO8601DateFormatter.local.string(from: Date())]

        // HealthKit reports no per-type denial, so an all-empty run is the only signal that reads
        // were refused or the device was locked. Writing then would replace a good snapshot with
        // _meta only, and the Mac job would carry that to the NAS.
        guard metrics.count > 1 else {
            throw ExportError.writeFailed("no HealthKit data returned, previous export kept")
        }
        let workouts = enabled.contains(Selection.workouts) ? try await workoutRows(from: start) : []
        UserDefaults.standard.set(Date(), forKey: Schedule.lastRunKey)
        try publish(metrics, workouts, sessions, into: folder)
        return ExportSummary(metrics: metrics.count - 1,          // _meta is not a metric
                             workouts: workouts.count,
                             sessions: sleepData?.sessions.count ?? 0)
    }

    // Daily aggregate straight from HealthKit: no per-sample loop, so 2 years costs the same as 2 days.
    private func dailyPoints(type: HKQuantityType, spec: Spec, from start: Date) async throws -> [(d: String, v: Double)] {
        let query = HKStatisticsCollectionQuery(
            quantityType: type,
            quantitySamplePredicate: nil,
            options: spec.cumulative ? .cumulativeSum : .discreteAverage,
            anchorDate: cal.startOfDay(for: start),
            intervalComponents: DateComponents(day: 1))
        return try await withCheckedThrowingContinuation { cont in
            query.initialResultsHandler = { _, results, error in
                if let error { return cont.resume(throwing: error) }
                var out: [(String, Double)] = []
                results?.enumerateStatistics(from: start, to: Date()) { stat, _ in
                    let q = spec.cumulative ? stat.sumQuantity() : stat.averageQuantity()
                    guard let q, stat.startDate <= Date() else { return }
                    // HKUnit.percent() is already a 0..1 fraction (0.97 == 97 %); the cache stores
                    // fractions verbatim, so there is no division here. Dividing again was the bug.
                    let v = q.doubleValue(for: spec.unit(for: type))
                    out.append((Self.dayKey(stat.startDate), (v * 1000).rounded() / 1000))
                }
                cont.resume(returning: out)
            }
            store.execute(query)
        }
    }

    /// One query, two shapes: per-day hours for the cache and clustered sessions for
    /// health-sessions.json. Both come from the same samples, so the two surfaces cannot disagree.
    private func sleep(from start: Date) async throws -> (daily: [(d: String, v: Double)], sessions: [[String: Any]]) {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return ([], []) }
        let pred = HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)
        let all: [HKCategorySample] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: pred, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: nil) { _, items, error in
                if let error { return cont.resume(throwing: error) }
                cont.resume(returning: items as? [HKCategorySample] ?? [])
            }
            store.execute(q)
        }
        let samples = Self.preferWatch(all)
        var perDay: [String: Double] = [:]
        for s in Self.timeline(from: samples, values: Self.asleepRaw) {
            // credited to the WAKE day (endDate), same rule as before and as the server documents
            perDay[Self.dayKey(s.end), default: 0] += s.end.timeIntervalSince(s.start) / 3600
        }
        let daily = perDay.map { ($0.key, ($0.value * 1000).rounded() / 1000) }
        return (daily, Self.sessions(from: samples))
    }

    /// Third-party sleep apps (AutoSleep) write long "asleep" blocks over the Watch's staged
    /// night; merged, they stretch the night past what the Watch measured. Keep the Watch.
    /// shortcut: all-or-nothing over the whole lookback; a night with no Watch data drops out
    /// once any Watch data exists. Filter per night if the Watch is often left off.
    static func preferWatch(_ samples: [HKCategorySample]) -> [HKCategorySample] {
        let watch = samples.filter { $0.sourceRevision.productType?.hasPrefix("Watch") == true }
        return watch.isEmpty ? samples : watch
    }

    // .asleep is the pre-iOS-16 name for .asleepUnspecified: same raw value (1), so listing both
    // added nothing and only produced a deprecation warning.
    static let asleepRaw: Set<Int> = [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                                      HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                                      HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                                      HKCategoryValueSleepAnalysis.asleepREM.rawValue]

    /// Collapses overlapping same-kind intervals so two sources recording the same night count
    /// once instead of twice. Contiguous samples (end == next start) stay separate: those are
    /// real stage changes, not duplicates.
    /// ponytail: the interval that opened an overlap keeps its stage label; a source that merely
    /// extends it is absorbed. Split per source only if per-stage detail starts mattering.
    static func timeline(from samples: [HKCategorySample],
                         values: Set<Int>) -> [(start: Date, end: Date, value: Int)] {
        var out: [(start: Date, end: Date, value: Int)] = []
        for s in samples.filter({ values.contains($0.value) }).sorted(by: { $0.startDate < $1.startDate }) {
            if let last = out.last, s.startDate < last.end {
                if s.endDate > out[out.count - 1].end { out[out.count - 1].end = s.endDate }
            } else {
                out.append((s.startDate, s.endDate, s.value))
            }
        }
        return out
    }

    static let stageNames: [Int: String] = [HKCategoryValueSleepAnalysis.asleepCore.rawValue: "core",
                                            HKCategoryValueSleepAnalysis.asleepDeep.rawValue: "deep",
                                            HKCategoryValueSleepAnalysis.asleepREM.rawValue: "rem",
                                            HKCategoryValueSleepAnalysis.awake.rawValue: "awake"]

    /// Clusters sleep samples into nights. A gap longer than an hour starts a new session, which
    /// is what makes a split night two sessions instead of one invented 9-hour block.
    /// ponytail: fixed 60-minute gap; per-person tuning only if naps start being miscounted.
    static func sessions(from samples: [HKCategorySample], gap: TimeInterval = 3600) -> [[String: Any]] {
        let relevant = samples.filter { asleepRaw.contains($0.value) || $0.value == HKCategoryValueSleepAnalysis.awake.rawValue }
            .sorted { $0.startDate < $1.startDate }
        var groups: [[HKCategorySample]] = []
        for s in relevant {
            if let last = groups.last, let end = last.map({ $0.endDate }).max(),
               s.startDate.timeIntervalSince(end) <= gap {
                groups[groups.count - 1].append(s)
            } else {
                groups.append([s])
            }
        }
        return groups.compactMap { group in
            guard let first = group.first, let end = group.map({ $0.endDate }).max() else { return nil }
            let asleep = timeline(from: group, values: asleepRaw)
            guard !asleep.isEmpty else { return nil }
            let hours = asleep.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) } / 3600
            guard hours > 0 else { return nil }
            var stages: [String: Double] = [:]
            for g in asleep + timeline(from: group, values: [HKCategoryValueSleepAnalysis.awake.rawValue]) {
                guard let name = stageNames[g.value] else { continue }
                stages[name, default: 0] += g.end.timeIntervalSince(g.start) / 3600
            }
            var row: [String: Any] = [
                "start": ISO8601DateFormatter.local.string(from: first.startDate),
                "end": ISO8601DateFormatter.local.string(from: end),
                "day": dayKey(end),                       // waking day, as the server documents
                "hours": (hours * 1000).rounded() / 1000,
            ]
            if !stages.isEmpty {
                row["stages"] = stages.mapValues { ($0 * 100).rounded() / 100 }
            }
            return row
        }
    }

    private func workoutRows(from start: Date) async throws -> [[String: Any]] {
        let pred = HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)
        let items: [HKWorkout] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: .workoutType(), predicate: pred, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, items, error in
                if let error { return cont.resume(throwing: error) }
                cont.resume(returning: items as? [HKWorkout] ?? [])
            }
            store.execute(q)
        }
        return items.map { w in
            var row: [String: Any] = [
                "id": "ios-\(Int(w.workoutActivityType.rawValue))-\(ISO8601DateFormatter.local.string(from: w.startDate))",
                "name": Self.activityName(w.workoutActivityType),
                "activityType": Int(w.workoutActivityType.rawValue),
                "start": ISO8601DateFormatter.local.string(from: w.startDate),
                "end": ISO8601DateFormatter.local.string(from: w.endDate),
                "duration": Int(w.duration),
                "distanceSource": w.sourceRevision.source.name,
            ]
            if let e = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()) {
                row["activeEnergyBurned"] = Int(e.rounded())
            }
            // Distance lives in a type that follows the activity: a ride is not a walk.
            let distanceType: HKQuantityTypeIdentifier = switch w.workoutActivityType {
            case .cycling: .distanceCycling
            case .swimming: .distanceSwimming
            // rowing distance (iOS 18+) falls through to totalDistance below
            case .hiking, .walking, .running: .distanceWalkingRunning
            default: .distanceWalkingRunning
            }
            let meters = w.statistics(for: HKQuantityType(distanceType))?.sumQuantity()?.doubleValue(for: .meter())
                ?? w.totalDistance?.doubleValue(for: .meter())
            if let meters, meters > 0 { row["distanceMeters"] = Int(meters.rounded()) }
            if let hr = w.statistics(for: HKQuantityType(.heartRate)) {
                if let a = hr.averageQuantity()?.doubleValue(for: .count().unitDivided(by: .minute())) {
                    row["avgHeartRate"] = Int(a.rounded())
                }
                if let m = hr.maximumQuantity()?.doubleValue(for: .count().unitDivided(by: .minute())) {
                    row["maxHeartRate"] = Int(m.rounded())
                }
            }
            if let el = w.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity {
                row["elevationAscendedMeters"] = Int(el.doubleValue(for: .meter()).rounded())
            }
            return row
        }
    }

    /// Every payload is fully written under a temporary name first, then renamed, so a reader never
    /// sees a new metrics file beside last cycle's workouts file. Empty sessions are skipped: an
    /// absent file is the server's explicit "never exported", an empty array would pretend otherwise.
    private func publish(_ metrics: [String: Any], _ workouts: [[String: Any]],
                         _ sessions: [String: Any], into folder: URL) throws {
        var pairs: [(String, Any)] = [(".health-cache.json", metrics), (".health-workouts-cache.json", workouts)]
        if let rows = sessions["sessions"] as? [[String: Any]], !rows.isEmpty {
            pairs.append(("health-sessions.json", sessions))
        }
        var staged: [(URL, URL)] = []
        for (name, object) in pairs {
            let final = folder.appendingPathComponent(name)
            let temp = folder.appendingPathComponent(name + ".tmp")
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try data.write(to: temp, options: .atomic)
            staged.append((temp, final))
        }
        for (temp, final) in staged {
            if FileManager.default.fileExists(atPath: final.path) {
                _ = try FileManager.default.replaceItemAt(final, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: final)
            }
        }
    }

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// HKWorkoutActivityType raw values straight from the SDK header. A switch would be 86 cases
    /// and would fail to compile on an SDK that lacks one; a table cannot, and "Other" is then
    /// reserved for a type Apple adds after this build.
    static let activityNames: [Int: String] = [
        1: "American Football",
        2: "Archery",
        3: "Australian Football",
        4: "Badminton",
        5: "Baseball",
        6: "Basketball",
        7: "Bowling",
        8: "Boxing",
        9: "Climbing",
        10: "Cricket",
        11: "Cross Training",
        12: "Curling",
        13: "Cycling",
        14: "Dance",
        15: "Dance Inspired Training",
        16: "Elliptical",
        17: "Equestrian Sports",
        18: "Fencing",
        19: "Fishing",
        20: "Functional Strength Training",
        21: "Golf",
        22: "Gymnastics",
        23: "Handball",
        24: "Hiking",
        25: "Hockey",
        26: "Hunting",
        27: "Lacrosse",
        28: "Martial Arts",
        29: "Mind And Body",
        30: "Mixed Metabolic Cardio Training",
        31: "Paddle Sports",
        32: "Play",
        33: "Preparation And Recovery",
        34: "Racquetball",
        35: "Rowing",
        36: "Rugby",
        37: "Running",
        38: "Sailing",
        39: "Skating Sports",
        40: "Snow Sports",
        41: "Soccer",
        42: "Softball",
        43: "Squash",
        44: "Stair Climbing",
        45: "Surfing Sports",
        46: "Swimming",
        47: "Table Tennis",
        48: "Tennis",
        49: "Track And Field",
        50: "Traditional Strength Training",
        51: "Volleyball",
        52: "Walking",
        53: "Water Fitness",
        54: "Water Polo",
        55: "Water Sports",
        56: "Wrestling",
        57: "Yoga",
        58: "Barre",
        59: "Core Training",
        60: "Cross Country Skiing",
        61: "Downhill Skiing",
        62: "Flexibility",
        63: "HIIT",
        64: "Jump Rope",
        65: "Kickboxing",
        66: "Pilates",
        67: "Snowboarding",
        68: "Stairs",
        69: "Step Training",
        70: "Wheelchair Walk Pace",
        71: "Wheelchair Run Pace",
        72: "Tai Chi",
        73: "Mixed Cardio",
        74: "Hand Cycling",
        75: "Disc Sports",
        76: "Fitness Gaming",
        77: "Cardio Dance",
        78: "Social Dance",
        79: "Pickleball",
        80: "Cooldown",
        82: "Swim Bike Run",
        83: "Transition",
        84: "Underwater Diving",
        2998: "Rest",
        2999: "Group",
        3000: "Other",
    ]

    static func activityName(_ t: HKWorkoutActivityType) -> String {
        activityNames[Int(t.rawValue)] ?? "Other"
    }
}

extension Spec {
    /// HealthKit's native unit per metric, so no value is silently converted twice.
    func unit(for type: HKQuantityType) -> HKUnit {
        switch id {
        case .stepCount, .flightsClimbed: return .count()
        case .distanceWalkingRunning: return .meterUnit(with: .kilo)
        case .activeEnergyBurned, .basalEnergyBurned: return .kilocalorie()
        case .appleExerciseTime, .appleStandTime: return .minute()
        case .dietaryWater: return .liter()
        case .heartRate, .restingHeartRate, .walkingHeartRateAverage, .respiratoryRate:
            return .count().unitDivided(by: .minute())
        case .heartRateVariabilitySDNN: return .secondUnit(with: .milli)
        case .oxygenSaturation, .bodyFatPercentage: return .percent()
        case .bodyMass: return .gramUnit(with: .kilo)
        case .vo2Max: return HKUnit.literUnit(with: .milli).unitDivided(by: .gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        case .walkingSpeed: return .meterUnit(with: .kilo).unitDivided(by: .hour())
        case .appleSleepingWristTemperature: return .degreeCelsius()
        default: return .count()
        }
    }
}

extension ISO8601DateFormatter {
    static let local: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current   // server dates workouts by the first 10 chars: they must be LOCAL
        return f
    }()
}


#if DEBUG
extension Exporter {
    /// Writes a sample cache through the SAME publish() path the real export uses.
    /// Only exists so the writer can be tested where HealthKit cannot run (simulator).
    func writeSampleCache(into folder: URL) throws -> ExportSummary {
        let day = { (offset: Int) -> String in
            let d = Calendar.current.date(byAdding: .day, value: -offset, to: Date())!
            return Self.dayKey(d)
        }
        func series(_ unit: String, _ cumulative: Bool, _ values: [Double]) -> [String: Any] {
            ["unit": unit, "cumulative": cumulative,
             "daily": Array(values.enumerated().map { ["d": day($0.offset), "v": $0.element] }.reversed())]
        }
        let metrics: [String: Any] = [
            "step_count": series("count", true, [9123, 7455, 10233]),
            "walking_running_distance": series("km", true, [6.4, 5.1, 7.8]),
            "active_energy": series("kcal", true, [612, 388, 741]),
            "heart_rate": series("count/min", false, [72, 68, 75]),
            "resting_heart_rate": series("count/min", false, [54, 52, 55]),
            "heart_rate_variability": series("ms", false, [57.2, 61.4, 55.9]),
            "blood_oxygen_saturation": series("%", false, [0.97, 0.98, 0.96]),
            "vo2_max": series("mL/min/kg", false, [44.1, 44.3, 43.9]),
            "_meta": ["schema": 1, "app": "healthsync-ios-sample",
                      "requested": SPECS.count, "written": 8,
                      "writtenAt": ISO8601DateFormatter.local.string(from: Date())],
        ]
        let workouts: [[String: Any]] = [
            ["id": "sample-1", "name": "Running", "activityType": 37,
             "start": ISO8601DateFormatter.local.string(from: Date().addingTimeInterval(-7200)),
             "end": ISO8601DateFormatter.local.string(from: Date().addingTimeInterval(-4500)),
             "duration": 2700, "activeEnergyBurned": 480, "distanceMeters": 7500,
             "avgHeartRate": 148, "maxHeartRate": 172],
            ["id": "sample-2", "name": "Functional Strength Training", "activityType": 20,
             "start": ISO8601DateFormatter.local.string(from: Date().addingTimeInterval(-90000)),
             "end": ISO8601DateFormatter.local.string(from: Date().addingTimeInterval(-86400)),
             "duration": 3600, "activeEnergyBurned": 310,
             "avgHeartRate": 118, "maxHeartRate": 150],
            ["id": "sample-3", "name": "Hiking", "activityType": 24,
             "start": ISO8601DateFormatter.local.string(from: Date().addingTimeInterval(-260000)),
             "end": ISO8601DateFormatter.local.string(from: Date().addingTimeInterval(-245000)),
             "duration": 15000, "activeEnergyBurned": 940, "distanceMeters": 11200,
             "avgHeartRate": 116, "maxHeartRate": 158],
        ]
        // A sample night that goes through the REAL sessions(from:), so the clustering and the
        // session file's shape are exercised without HealthKit. Two sessions: the gap after the
        // REM block is 1.2 h, past the 1 h threshold.
        let night = Self.sessions(from: [
            Self.sample(.asleepCore, startHoursAgo: 9, hours: 4),
            Self.sample(.asleepDeep, startHoursAgo: 5, hours: 1.5),
            Self.sample(.asleepREM, startHoursAgo: 3.5, hours: 1.8),
            Self.sample(.asleepCore, startHoursAgo: 0.5, hours: 0.75),
        ])
        guard night.count == 2 else { throw ExportError.writeFailed("sessions: expected 2, got \(night.count)") }

        // nextFire is the only real logic behind the schedule: three cases worth proving
        let cal = Calendar.current
        let slots = [7 * 60, 12 * 60, 23 * 60 + 30]
        let at10 = cal.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
        let at2359 = cal.date(bySettingHour: 23, minute: 59, second: 0, of: Date())!
        let clock = { (d: Date) in (cal.component(.hour, from: d), cal.component(.minute, from: d)) }
        let midday = Schedule.nextFire(after: at10, times: slots)          // -> 12:00 today
        let overnight = Schedule.nextFire(after: at2359, times: slots)     // -> 07:00 tomorrow
        guard clock(midday) == (12, 0), clock(overnight) == (7, 0),
              midday.timeIntervalSince(at10) > 0, midday.timeIntervalSince(at10) < 3 * 3600,
              overnight.timeIntervalSince(at2359) > 6 * 3600, overnight.timeIntervalSince(at2359) < 8 * 3600 else {
            throw ExportError.writeFailed("nextFire wrong: \(midday) / \(overnight)")
        }
        try publish(metrics, workouts, ["schema": 1, "writtenAt": ISO8601DateFormatter.local.string(from: Date()),
                                       "sessions": night], into: folder)
        return ExportSummary(metrics: metrics.count - 1, workouts: workouts.count, sessions: night.count)
    }

    private static func sample(_ value: HKCategoryValueSleepAnalysis, startHoursAgo: Double, hours: Double) -> HKCategorySample {
        let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        let start = Date().addingTimeInterval(-startHoursAgo * 3600)
        return HKCategorySample(type: type, value: value.rawValue, start: start, end: start.addingTimeInterval(hours * 3600))
    }
}
#endif

// MARK: - Folder bookmark (write access survives relaunches without any entitlement)

enum FolderStore {
    static func save(_ url: URL) throws {
        let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: BOOKMARK_KEY)
    }

    static func url() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: BOOKMARK_KEY) else { return nil }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale { try? save(url) }
            return url
        } catch {
            UserDefaults.standard.removeObject(forKey: BOOKMARK_KEY)   // re-pick instead of failing forever
            return nil
        }
    }
}

// MARK: - UI

@MainActor
final class SyncModel: ObservableObject {
    @Published var status = "Noch nicht exportiert"
    @Published var folderName: String?
    @Published var busy = false
    @Published var summary: ExportSummary?
    @Published var lastExport: Date? = Schedule.lastRun

    let exporter = Exporter()

    /// Appends one line to Documents/last-run.log, readable from the Mac with devicectl.
    /// The status line is invisible to whoever debugs this over USB; this is not.
    func log(_ message: String) {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let file = dir.appendingPathComponent("last-run.log")
        let line = "\(ISO8601DateFormatter.local.string(from: Date())) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }

    init() {
        folderName = FolderStore.url()?.lastPathComponent
        log("launch: folder=\(folderName ?? "none")")
    }

    func setFolder(_ url: URL) {
        // The picker returns a SECURITY-SCOPED url. Without taking the scope, even reading the
        // folder to build a bookmark fails with "The file couldn't be opened because it doesn't
        // exist" (NSFileNoSuchFileError), and no bookmark is ever stored.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try FolderStore.save(url)
            folderName = url.lastPathComponent
            status = "Ordner gesetzt"
            log("folder set: \(url.path)")
            Background.schedule()      // a schedule submitted before the folder existed was a no-op
        } catch {
            status = "Ordner merken fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func exportNow() async {
        busy = true
        defer { busy = false }
        do {
            // Authorize BEFORE the folder check: otherwise a fresh install never shows the
            // Health permission sheet until the owner happens to tap export a second time.
            try await exporter.authorize()
            log("authorize ok")
            guard let folder = FolderStore.url() else {
                status = "Berechtigung erteilt. Jetzt einen Ordner wählen (iCloud Drive)."
                return
            }
            status = "Exportiere…"
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            summary = try await exporter.run(into: folder)
            lastExport = Date()
            status = "Fertig · \(Self.stamp())"
            log("export ok -> \(folder.path)")
        } catch {
            status = "Fehler: \(error.localizedDescription)"
            log("ERROR: \(error.localizedDescription)")
        }
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "dd.MM. HH:mm"
        return f.string(from: Date())
    }
}

struct ContentView: View {
    @EnvironmentObject var model: SyncModel
    @State private var picking = false
    @State private var showSelection = false   // DEBUG seed only: opens the screen for a screenshot
    @AppStorage(Schedule.enabledKey) private var autoOn = false
    @State private var times: [Int] = Schedule.times

    /// Rows edit minutes after midnight; a Date exists only because the picker wants one.
    private func binding(for value: Int) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: value / 60, minute: value % 60, second: 0, of: Date()) ?? Date() },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                guard let i = times.firstIndex(of: value) else { return }
                times[i] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                save()
            })
    }

    /// Sorted and deduped on every change: two identical slots would ask iOS for the same moment.
    private func save() {
        times.sort()
        var seen = Set<Int>()
        times = times.filter { seen.insert($0).inserted }
        Schedule.times = times
        Background.schedule()
    }

    private var statusTitle: String {
        if model.busy { return "Export läuft" }
        guard let when = model.lastExport else { return "Noch kein Export" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "Exportiert " + f.localizedString(for: when, relativeTo: Date())
    }

    private var scheduleFooter: String {
        guard autoOn else { return "Aus. Der Export startet nur, wenn du die App öffnest." }
        let f = DateFormatter()
        f.dateFormat = "EE dd.MM. HH:mm"
        let next = f.string(from: Schedule.nextFire(after: Date(), times: Schedule.times))
        let last = Schedule.lastRun.map { f.string(from: $0) } ?? "noch nie"
        return "Frühestens \(next). Zuletzt \(last). iOS entscheidet den genauen Zeitpunkt."
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var rule: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 28)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: "waveform.path.ecg")
                                .font(.title2)
                                .foregroundStyle(.red)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(statusTitle)
                                    .font(.headline)
                                Text(model.status)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if model.busy { ProgressView() }
                        }
                        HStack(spacing: 0) {
                            stat("Metriken", model.summary.map { "\($0.metrics)" } ?? "—")
                            rule
                            stat("Workouts", model.summary.map { "\($0.workouts)" } ?? "—")
                            rule
                            stat("Nächte", model.summary.map { "\($0.sessions)" } ?? "—")
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    NavigationLink {
                        DataSelectionView()
                    } label: {
                        Label("Daten auswählen", systemImage: "slider.horizontal.3")
                    }
                } footer: {
                    Text("Was du abwählst, fehlt dem Agenten. Die Auswahl gilt ab dem nächsten Export.")
                }

                Section {
                    Button {
                        Task { await model.exportNow() }
                    } label: {
                        Label("Jetzt exportieren", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.busy)

                    Button {
                        picking = true
                    } label: {
                        HStack {
                            Label("Zielordner", systemImage: "folder")
                            Spacer()
                            Text(model.folderName ?? "Wählen")
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Nur lesen. Der Export landet im gewählten Ordner und wird von dort weiterkopiert.")
                }

                Section {
                    Toggle("Automatisch exportieren", isOn: $autoOn)
                        .onChange(of: autoOn) { _, _ in Background.schedule() }
                    if autoOn {
                        ForEach(Array(times.enumerated()), id: \.element) { index, value in
                            DatePicker("Uhrzeit \(index + 1)", selection: binding(for: value),
                                       displayedComponents: .hourAndMinute)
                        }
                        .onDelete { offsets in
                            guard times.count > offsets.count else { return }   // keep one slot
                            times.remove(atOffsets: offsets)
                            save()
                        }
                        Button {
                            // first full hour nobody claimed, so the new row is never a duplicate
                            let used = Set(times.map { $0 / 60 })
                            times.append(((0..<24).first { !used.contains($0) } ?? 12) * 60)
                            save()
                        } label: {
                            Label("Uhrzeit hinzufügen", systemImage: "plus.circle")
                        }
                    }
                } header: {
                    Text("Hintergrund")
                } footer: {
                    Text(scheduleFooter)
                }

            }
            .listStyle(.insetGrouped)
            .navigationTitle("HealthSync")
            .navigationDestination(isPresented: $showSelection) { DataSelectionView() }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { model.setFolder(url) }
                else if case .failure(let error) = result { model.status = "Ordner: \(error.localizedDescription)" }
            }
            .task {
                #if DEBUG
                if CommandLine.arguments.contains("-seed") {
                    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    do {
                        let summary = try Exporter().writeSampleCache(into: docs)
                        // ponytail: DEBUG-only fixture so the screenshots show a configured app
                        let demo = docs.appendingPathComponent("Health MCP (Demo)", isDirectory: true)
                        try? FileManager.default.createDirectory(at: demo, withIntermediateDirectories: true)
                        try? FolderStore.save(demo)
                        model.folderName = demo.lastPathComponent
                        model.summary = summary
                        model.lastExport = Date().addingTimeInterval(-6 * 3600)
                        Schedule.times = [7 * 60, 22 * 60 + 30]
                        times = Schedule.times          // @State was built before the seed ran
                        UserDefaults.standard.set(model.lastExport, forKey: Schedule.lastRunKey)
                        model.status = "Beispieldaten geschrieben"
                        model.log("seed: \(docs.path)")
                    showSelection = CommandLine.arguments.contains("-selection")
                    } catch { model.status = "Seeder: \(error.localizedDescription)" }
                    return
                }
                #endif
                await model.exportNow()   // export on launch: Health is only readable while unlocked
            }
        }
    }
}

// MARK: - Schedule (iOS has no cron; this is an earliest-run hint, not a promise)

enum Schedule {
    static let enabledKey = "schedule.enabled"
    static let timesKey   = "schedule.times"       // [minutes after midnight], sorted
    static let legacyKey  = "schedule.minutes"     // the single-time version
    static let lastRunKey = "schedule.lastRun"
    static let defaultTimes = [23 * 60 + 30]

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var times: [Int] {
        get {
            let stored = UserDefaults.standard.array(forKey: timesKey) as? [Int] ?? []
            if !stored.isEmpty { return stored.sorted() }
            if let legacy = UserDefaults.standard.object(forKey: legacyKey) as? Int { return [legacy] }
            return defaultTimes
        }
        set { UserDefaults.standard.set(Array(Set(newValue)).sorted(), forKey: timesKey) }
    }

    static var lastRun: Date? { UserDefaults.standard.object(forKey: lastRunKey) as? Date }

    /// The next slot in the list: the first time still ahead today, else the earliest one tomorrow.
    /// BGTaskScheduler holds ONE pending request per identifier, so "several times a day" means each
    /// run submits the next slot — never a queue of requests.
    static func nextFire(after now: Date, times: [Int], calendar: Calendar = .current) -> Date {
        let slots = (times.isEmpty ? defaultTimes : times).sorted()
        let today = slots.compactMap {
            calendar.date(bySettingHour: $0 / 60, minute: $0 % 60, second: 0, of: now)
        }
        if let next = today.first(where: { $0 > now }) { return next }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        return calendar.date(bySettingHour: slots[0] / 60, minute: slots[0] % 60, second: 0, of: tomorrow) ?? tomorrow
    }
}

// MARK: - Daily background refresh

final class Background: NSObject, UIApplicationDelegate {
    func application(_ app: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // BGProcessing, not BGAppRefresh: a full 730-day export takes ~35 s on device and an
        // app-refresh task is killed at 30. Processing tasks get minutes, typically while charging.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: REFRESH_ID, using: .main) { task in
            guard let run = task as? BGProcessingTask else { return task.setTaskCompleted(success: false) }
            Self.schedule()
            let work = Task {
                guard let folder = FolderStore.url() else {
                    throw ExportError.noFolder     // a silent success would hide a dead pipeline
                }
                let scoped = folder.startAccessingSecurityScopedResource()
                defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                let exporter = Exporter()
                try await exporter.authorize()
                try await exporter.run(into: folder)
            }
            run.expirationHandler = { work.cancel() }
            Task {
                let ok = (try? await work.value) != nil
                run.setTaskCompleted(success: ok)
            }
        }
        Self.schedule()
        return true
    }

    /// Submits exactly one pending request, derived from the user's chosen time. Turning the
    /// schedule off cancels it — otherwise a stale request keeps firing after "aus".
    static func schedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: REFRESH_ID)
        guard Schedule.enabled, FolderStore.url() != nil else { return }
        let request = BGProcessingTaskRequest(identifier: REFRESH_ID)
        request.earliestBeginDate = Schedule.nextFire(after: Date(), times: Schedule.times)
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }
}

@main
struct HealthSyncApp: App {
    @UIApplicationDelegateAdaptor(Background.self) var background
    @StateObject private var model = SyncModel()

    var body: some Scene {
        WindowGroup { ContentView().environmentObject(model) }
    }
}

// MARK: - Data selection

/// What leaves the phone. Toggles write straight to Selection; nothing re-exports by itself,
/// the next run (manual or background) picks the new set up.
struct DataSelectionView: View {
    @State private var on: Set<String> = Selection.names

    /// Category order as it first appears in SPECS, so the table stays the only place to edit.
    private var cats: [String] {
        var seen = Set<String>(), out: [String] = []
        for s in SPECS where seen.insert(s.cat).inserted { out.append(s.cat) }
        return out
    }

    var body: some View {
        List {
            ForEach(cats, id: \.self) { cat in
                Section(cat) {
                    ForEach(SPECS.filter { $0.cat == cat }, id: \.name) { spec in
                        row(spec.label, spec.name)
                    }
                }
            }
            Section {
                row("Schlaf (Nächte & Phasen)", SLEEP_NAME)
                row("Workouts", Selection.workouts)
            } header: {
                Text("Weiteres")
            } footer: {
                Text("Abgewählte Werte fehlen im Export und damit in den Antworten des Agenten.")
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(on.count) von \(Selection.all.count) aktiv")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                if on.count == Selection.all.count {
                    Text("alles an").font(.footnote).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle("Daten")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Alle") { on = Set(Selection.all) }
                    .disabled(on.count == Selection.all.count)
            }
        }
        .onChange(of: on) { _, new in Selection.names = new }
    }

    private func row(_ label: String, _ name: String) -> some View {
        Toggle(label, isOn: Binding(
            get: { on.contains(name) },
            set: { if $0 { on.insert(name) } else { on.remove(name) } }))
    }
}

