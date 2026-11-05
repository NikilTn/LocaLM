import Foundation
import UIKit

// Deterministic helpers. Small models are unreliable at arithmetic, unit conversion, and date math,
// so the model passes the numbers and the app computes the answer.

/// Arithmetic: + - * / ^ %, parentheses, unary minus, sqrt(), "x"/"×"/"÷". No eval, no NSExpression.
enum Calculator {
    struct ParseError: Error { var message: String }

    static func evaluate(_ input: String) throws -> Double {
        var s = input.lowercased()
            .replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "of", with: "*") // "15% of 80"
        s = s.replacingOccurrences(of: #"(?<=\d)\s*x\s*(?=[\d(])"#, with: "*", options: .regularExpression)
        var parser = Parser(chars: Array(s.filter { !$0.isWhitespace }))
        let value = try parser.expression()
        guard parser.index == parser.chars.count else { throw ParseError(message: "Unexpected '\(parser.chars[parser.index])'") }
        guard value.isFinite else { throw ParseError(message: "The result is not a finite number (division by zero?)") }
        return value
    }

    private struct Parser {
        let chars: [Character]
        var index = 0
        var depth = 0

        mutating func peek() -> Character? { index < chars.count ? chars[index] : nil }

        mutating func expression() throws -> Double {
            var value = try term()
            while let c = peek(), c == "+" || c == "-" {
                index += 1
                let rhs = try term()
                value = c == "+" ? value + rhs : value - rhs
            }
            return value
        }

        mutating func term() throws -> Double {
            var value = try power()
            while let c = peek(), c == "*" || c == "/" {
                index += 1
                let rhs = try power()
                value = c == "*" ? value * rhs : value / rhs
            }
            return value
        }

        mutating func power() throws -> Double {
            let base = try unary()
            if peek() == "^" {
                index += 1
                return Foundation.pow(base, try power()) // right-associative
            }
            return base
        }

        mutating func unary() throws -> Double {
            if peek() == "-" { index += 1; return -(try unary()) }
            if peek() == "+" { index += 1; return try unary() }
            return try postfix()
        }

        mutating func postfix() throws -> Double {
            var value = try primary()
            while peek() == "%" { index += 1; value /= 100 }
            return value
        }

        mutating func primary() throws -> Double {
            depth += 1
            defer { depth -= 1 }
            guard depth < 50 else { throw ParseError(message: "Expression too deeply nested") }
            if chars[index...].starts(with: "sqrt") {
                index += 4
                guard peek() == "(" else { throw ParseError(message: "sqrt needs parentheses") }
                return Foundation.sqrt(try primary())
            }
            if peek() == "(" {
                index += 1
                let v = try expression()
                guard peek() == ")" else { throw ParseError(message: "Missing ')'") }
                index += 1
                return v
            }
            let start = index
            while let c = peek(), c.isNumber || c == "." { index += 1 }
            guard index > start, let v = Double(String(chars[start..<index])) else {
                throw ParseError(message: peek().map { "Unexpected '\($0)'" } ?? "Expression ended early")
            }
            return v
        }
    }

    static func format(_ v: Double) -> String {
        if v.rounded() == v && abs(v) < 1e15 { return String(Int64(v)) }
        let f = NumberFormatter()
        f.maximumSignificantDigits = 10
        f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }
}

struct CalculateTool: AssistantTool {
    let group = ToolGroup.utilities
    let spec = ToolSpec(
        name: "calculate",
        description: "Compute an arithmetic expression exactly. Use for any math with specific numbers.",
        parameters: Schema.object([
            ("expression", Schema.string("e.g. '0.15 * 80', '(120 + 35) / 3', '2^10', '18% of 64.50'")),
        ], required: ["expression"]))

    func prepare(_ call: ToolCall) async throws -> PreparedAction {
        let expr = (call["expression"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let value: Double
        do {
            value = try Calculator.evaluate(expr)
        } catch let e as Calculator.ParseError {
            throw ToolPreparationError.invalidArguments("Could not compute '\(expr)': \(e.message). Rewrite it using numbers and + - * / ^ %.")
        }
        let result = Calculator.format(value)
        return PreparedAction(title: "Calculate", summary: "\(expr) = \(result)", icon: "function", requiresConfirmation: false) {
            ToolOutcome(success: true, display: "\(expr) = \(result)",
                        payload: .object([("expression", .string(expr)), ("result", .string(result))]))
        }
    }
}

/// Unit conversion with Foundation's Measurement types.
enum UnitConverter {
    private static let units: [String: Dimension] = {
        var m: [String: Dimension] = [:]
        func add(_ unit: Dimension, _ names: String...) { for n in names { m[n] = unit } }
        add(UnitLength.meters, "m", "meter", "meters", "metre", "metres")
        add(UnitLength.kilometers, "km", "kilometer", "kilometers", "kilometre", "kilometres")
        add(UnitLength.centimeters, "cm", "centimeter", "centimeters", "centimetre", "centimetres")
        add(UnitLength.millimeters, "mm", "millimeter", "millimeters")
        add(UnitLength.miles, "mi", "mile", "miles")
        add(UnitLength.feet, "ft", "foot", "feet")
        add(UnitLength.inches, "in", "inch", "inches")
        add(UnitLength.yards, "yd", "yard", "yards")
        add(UnitMass.kilograms, "kg", "kilogram", "kilograms", "kilo", "kilos")
        add(UnitMass.grams, "g", "gram", "grams")
        add(UnitMass.milligrams, "mg", "milligram", "milligrams")
        add(UnitMass.pounds, "lb", "lbs", "pound", "pounds")
        add(UnitMass.ounces, "oz", "ounce", "ounces")
        add(UnitMass.stones, "st", "stone", "stones")
        add(UnitTemperature.celsius, "c", "°c", "celsius", "degrees celsius", "centigrade")
        add(UnitTemperature.fahrenheit, "f", "°f", "fahrenheit", "degrees fahrenheit")
        add(UnitTemperature.kelvin, "k", "kelvin")
        add(UnitVolume.liters, "l", "liter", "liters", "litre", "litres")
        add(UnitVolume.milliliters, "ml", "milliliter", "milliliters", "millilitre", "millilitres")
        add(UnitVolume.gallons, "gal", "gallon", "gallons")
        add(UnitVolume.quarts, "qt", "quart", "quarts")
        add(UnitVolume.pints, "pt", "pint", "pints")
        // Foundation's `cups` is the 240 mL "legal" cup; recipes use the 236.6 mL customary cup.
        add(UnitVolume(symbol: "cup", converter: UnitConverterLinear(coefficient: 0.2365882365)), "cup", "cups")
        add(UnitVolume.fluidOunces, "fl oz", "fluid ounce", "fluid ounces")
        add(UnitVolume.tablespoons, "tbsp", "tablespoon", "tablespoons")
        add(UnitVolume.teaspoons, "tsp", "teaspoon", "teaspoons")
        add(UnitSpeed.kilometersPerHour, "km/h", "kph", "kmh", "kilometers per hour")
        add(UnitSpeed.milesPerHour, "mph", "miles per hour")
        add(UnitSpeed.metersPerSecond, "m/s", "meters per second")
        add(UnitSpeed.knots, "knot", "knots", "kn")
        add(UnitArea.squareMeters, "m2", "m²", "sq m", "square meter", "square meters")
        add(UnitArea.squareFeet, "ft2", "ft²", "sq ft", "square foot", "square feet")
        add(UnitArea.acres, "acre", "acres")
        add(UnitArea.hectares, "ha", "hectare", "hectares")
        add(UnitArea.squareKilometers, "km2", "km²", "sq km", "square kilometers")
        add(UnitArea.squareMiles, "sq mi", "square mile", "square miles")
        add(UnitDuration.seconds, "s", "sec", "second", "seconds")
        add(UnitDuration.minutes, "min", "minute", "minutes")
        add(UnitDuration.hours, "h", "hr", "hour", "hours")
        return m
    }()

    static func unit(_ name: String) -> Dimension? {
        let n = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "degrees ", with: "")
        if let u = units[n] { return u }
        if n.hasPrefix("degree") { return nil }
        return units[n.replacingOccurrences(of: "°", with: "")]
    }

    private static func family(_ u: Dimension) -> String {
        switch u {
        case is UnitLength: return "length"
        case is UnitMass: return "mass"
        case is UnitTemperature: return "temperature"
        case is UnitVolume: return "volume"
        case is UnitSpeed: return "speed"
        case is UnitArea: return "area"
        case is UnitDuration: return "duration"
        default: return "other"
        }
    }

    static func convert(_ value: Double, from: String, to: String) throws -> Double {
        guard let f = unit(from) else { throw Calculator.ParseError(message: "Unknown unit '\(from)'") }
        guard let t = unit(to) else { throw Calculator.ParseError(message: "Unknown unit '\(to)'") }
        // Compare unit families, not runtime classes (Foundation's built-in units are private subclasses).
        guard family(f) == family(t) else { throw Calculator.ParseError(message: "Can't convert \(from) to \(to)") }
        return Measurement(value: value, unit: f).converted(to: t).value
    }
}

struct ConvertUnitsTool: AssistantTool {
    let group = ToolGroup.utilities
    let spec = ToolSpec(
        name: "convert_units",
        description: "Convert a value between units (length, weight, temperature, volume, speed, area).",
        parameters: Schema.object([
            ("value", Schema.string("The number, e.g. '5'")),
            ("from", Schema.string("Unit to convert from, e.g. 'miles', 'lb', 'fahrenheit'")),
            ("to", Schema.string("Unit to convert to, e.g. 'km', 'kg', 'celsius'")),
        ], required: ["value", "from", "to"]))

    func prepare(_ call: ToolCall) async throws -> PreparedAction {
        let rawValue = (call["value"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let from = call["from"] ?? "", to = call["to"] ?? ""
        guard let value = try? Calculator.evaluate(rawValue) else {
            throw ToolPreparationError.invalidArguments("Missing or invalid 'value' '\(rawValue)'. Ask the user for the number.")
        }
        let result: Double
        do { result = try UnitConverter.convert(value, from: from, to: to) } catch let e as Calculator.ParseError {
            throw ToolPreparationError.invalidArguments(e.message + ". Use common unit names like km, miles, kg, lb, celsius, fahrenheit, liters, cups.")
        }
        let f = NumberFormatter()
        f.maximumFractionDigits = 2
        let text = "\(Calculator.format(value)) \(from) = \(f.string(from: NSNumber(value: result)) ?? "\(result)") \(to)"
        return PreparedAction(title: "Convert", summary: text, icon: "arrow.left.arrow.right", requiresConfirmation: false) {
            ToolOutcome(success: true, display: text, payload: .object([("result", .string(text))]))
        }
    }
}

/// "How many days until Christmas?" — holidays plus anything DateResolver understands.
struct DaysUntilTool: AssistantTool {
    let group = ToolGroup.utilities
    let spec = ToolSpec(
        name: "days_until",
        description: "Count the days from today until (or since) a date, and give its weekday.",
        parameters: Schema.object([("date", Schema.string("The date or holiday as the user said it, e.g. 'Christmas', 'March 3', 'next Friday'"))],
                                  required: ["date"]))

    static func holiday(_ text: String, now: Date) -> Date? {
        let t = text.lowercased()
        let cal = Calendar.current
        let year = cal.component(.year, from: now)
        func next(month: Int, day: Int) -> Date? {
            for y in [year, year + 1] {
                if let d = cal.date(from: DateComponents(year: y, month: month, day: day)), d >= cal.startOfDay(for: now) { return d }
            }
            return nil
        }
        if t.contains("christmas eve") { return next(month: 12, day: 24) }
        if t.contains("christmas") || t.contains("xmas") { return next(month: 12, day: 25) }
        if t.contains("new year's eve") || t.contains("new years eve") { return next(month: 12, day: 31) }
        if t.contains("new year") { return next(month: 1, day: 1) }
        if t.contains("halloween") { return next(month: 10, day: 31) }
        if t.contains("valentine") { return next(month: 2, day: 14) }
        if t.contains("independence day") || t.contains("july 4") || t.contains("4th of july") { return next(month: 7, day: 4) }
        if t.contains("thanksgiving") {
            for y in [year, year + 1] {
                var c = DateComponents(year: y, month: 11, weekday: 5)
                c.weekdayOrdinal = 4
                if let d = cal.date(from: c), d >= cal.startOfDay(for: now) { return d }
            }
        }
        return nil
    }

    func prepare(_ call: ToolCall) async throws -> PreparedAction {
        let phrase = (call["date"] ?? call["when"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let cal = Calendar.current
        var target = Self.holiday(phrase, now: now)
        if target == nil {
            // Past dates are fine here ("days since"), so use NSDataDetector-based parsing without the past check.
            switch DateResolver.resolve(phrase, now: now) {
            case .success(let r): target = r.date
            case .failure(.inPast(let d)): target = d
            case .failure(.unrecognized):
                throw ToolPreparationError.invalidArguments("Could not understand the date '\(phrase)'. Ask the user for a specific date.")
            }
        }
        let day = cal.startOfDay(for: target!)
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: day).day ?? 0
        let weekday = DateFormatter().weekdaySymbols[cal.component(.weekday, from: day) - 1]
        let text = days == 0 ? "\(DateResolver.displayDay(day)) is today"
            : days > 0 ? "\(days) day\(days == 1 ? "" : "s") until \(DateResolver.displayDay(day)) (a \(weekday))"
            : "\(-days) day\(days == -1 ? "" : "s") since \(DateResolver.displayDay(day)) (a \(weekday))"
        return PreparedAction(title: "Date math", summary: text, icon: "calendar.badge.clock", requiresConfirmation: false) {
            ToolOutcome(success: true, display: text, payload: .object([
                ("date", .string(DateResolver.isoDay(day))), ("weekday", .string(weekday)),
                ("days_from_today", .number(Double(days))), ("summary", .string(text)),
            ]))
        }
    }
}

struct WorldTimeTool: AssistantTool {
    let group = ToolGroup.utilities
    let spec = ToolSpec(
        name: "world_time",
        description: "Current local time in a city, country, or time zone.",
        parameters: Schema.object([("place", Schema.string("City, country, or zone, e.g. 'Tokyo', 'India', 'PST'"))], required: ["place"]))

    private static let aliases: [String: String] = [
        "india": "Asia/Kolkata", "mumbai": "Asia/Kolkata", "delhi": "Asia/Kolkata", "new delhi": "Asia/Kolkata",
        "bangalore": "Asia/Kolkata", "bengaluru": "Asia/Kolkata", "hyderabad": "Asia/Kolkata", "chennai": "Asia/Kolkata",
        "san francisco": "America/Los_Angeles", "seattle": "America/Los_Angeles", "la": "America/Los_Angeles",
        "california": "America/Los_Angeles", "boston": "America/New_York", "washington dc": "America/New_York",
        "miami": "America/New_York", "texas": "America/Chicago", "dallas": "America/Chicago", "houston": "America/Chicago",
        "austin": "America/Chicago", "beijing": "Asia/Shanghai", "china": "Asia/Shanghai", "japan": "Asia/Tokyo",
        "uk": "Europe/London", "england": "Europe/London", "germany": "Europe/Berlin", "france": "Europe/Paris",
        "spain": "Europe/Madrid", "italy": "Europe/Rome", "australia": "Australia/Sydney", "brazil": "America/Sao_Paulo",
        "canada": "America/Toronto", "uae": "Asia/Dubai", "korea": "Asia/Seoul", "south korea": "Asia/Seoul",
        "hawaii": "Pacific/Honolulu", "nyc": "America/New_York", "vancouver": "America/Vancouver",
    ]

    static func zone(_ place: String) -> TimeZone? {
        let p = place.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = aliases[p] { return TimeZone(identifier: id) }
        if p.count <= 5, let tz = TimeZone(abbreviation: p.uppercased()) { return tz }
        let key = p.replacingOccurrences(of: " ", with: "_")
        if let id = TimeZone.knownTimeZoneIdentifiers.first(where: { $0.lowercased().hasSuffix("/" + key) }) { return TimeZone(identifier: id) }
        return nil
    }

    func prepare(_ call: ToolCall) async throws -> PreparedAction {
        let place = (call["place"] ?? call["city"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tz = Self.zone(place) else {
            throw ToolPreparationError.invalidArguments("Unknown place '\(place)'. Ask for a major city in that time zone.")
        }
        let f = DateFormatter()
        f.timeZone = tz
        f.dateFormat = "EEE h:mm a"
        let hours = Double(tz.secondsFromGMT() - TimeZone.current.secondsFromGMT()) / 3600
        let diff = hours == 0 ? "same time as here" : String(format: "%@%g h from here", hours > 0 ? "+" : "", hours)
        let text = "\(place): \(f.string(from: Date())) (\(diff))"
        return PreparedAction(title: "World time", summary: text, icon: "globe", requiresConfirmation: false) {
            ToolOutcome(success: true, display: text, payload: .object([
                ("place", .string(place)), ("time_zone", .string(tz.identifier)),
                ("local_time", .string(f.string(from: Date()))), ("difference", .string(diff)),
            ]))
        }
    }
}

struct DeviceStatusTool: AssistantTool {
    let group = ToolGroup.device
    let spec = ToolSpec(name: "device_status", description: "Battery level, charging, Low Power Mode, and free storage on this iPhone.",
                        parameters: Schema.object([], required: []))

    func prepare(_ call: ToolCall) async throws -> PreparedAction {
        PreparedAction(title: "iPhone status", summary: "Battery and storage", icon: "battery.75percent",
                       requiresConfirmation: false) {
            await MainActor.run {
                UIDevice.current.isBatteryMonitoringEnabled = true
                let level = UIDevice.current.batteryLevel
                let state: String
                switch UIDevice.current.batteryState {
                case .charging: state = "charging"
                case .full: state = "full"
                case .unplugged: state = "on battery"
                default: state = "unknown"
                }
                let home = URL(fileURLWithPath: NSHomeDirectory())
                let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                    .volumeAvailableCapacityForImportantUsage ?? 0
                let freeText = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
                let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                let battery = level >= 0 ? "\(Int(level * 100))%" : "unknown"
                return ToolOutcome(
                    success: true,
                    display: "Battery \(battery), \(state)\(lowPower ? ", Low Power Mode on" : "") · \(freeText) free",
                    payload: .object([("battery", .string(battery)), ("charging_state", .string(state)),
                                      ("low_power_mode", .bool(lowPower)), ("free_storage", .string(freeText))]))
            }
        }
    }
}

struct DirectionsTool: AssistantTool {
    let group = ToolGroup.maps
    let spec = ToolSpec(
        name: "get_directions",
        description: "Open Apple Maps with directions to a place.",
        parameters: Schema.object([
            ("destination", Schema.string("Place or address")),
            ("mode", Schema.string("Optional: 'driving', 'walking', or 'transit'")),
        ], required: ["destination"]))

    /// Travel-mode words the model sometimes leaves inside the destination ("Anthropic SF office, public transport").
    private static let modeWords: [(pattern: String, flag: String)] = [
        (#"\b(public transport(ation)?|transit|by bus|bus|by train|train|subway|metro|bart|muni|caltrain)\b"#, "r"),
        (#"\b(walk(ing)?|on foot|by foot)\b"#, "w"),
        (#"\b(driv(e|ing)|by car)\b"#, "d"),
    ]

    static func mode(in text: String) -> String? {
        modeWords.first { text.range(of: $0.pattern, options: [.regularExpression, .caseInsensitive]) != nil }?.flag
    }

    static func cleanDestination(_ text: String) -> String {
        var d = text
        for (pattern, _) in modeWords {
            d = d.replacingOccurrences(of: #"[,\s]*(by |via |using )?"# + pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return d.trimmingCharacters(in: CharacterSet(charactersIn: " ,.-"))
    }

    func prepare(_ call: ToolCall) async throws -> PreparedAction {
        let raw = (call["destination"] ?? call["place"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = Self.cleanDestination(raw)
        guard !destination.isEmpty else { throw ToolPreparationError.invalidArguments("Missing 'destination'. Ask where to.") }
        // Mode: the model's argument, else mode words in the destination, else in the user's own message.
        let flag = Self.mode(in: call["mode"] ?? "") ?? Self.mode(in: raw) ?? Self.mode(in: ToolContext.userText) ?? "d"
        let modeName = ["r": "public transport", "w": "walking", "d": "driving"][flag]!
        var comps = URLComponents(string: "https://maps.apple.com/")!
        comps.queryItems = [URLQueryItem(name: "daddr", value: destination), URLQueryItem(name: "dirflg", value: flag)]
        let url = comps.url!
        return PreparedAction(title: "Directions", summary: "\(destination) · \(modeName)", icon: "map", requiresConfirmation: false) {
            var outcome = ToolOutcome(success: true, display: "Opening Maps: \(destination) by \(modeName).",
                                      payload: .object([("status", .string("opening_maps")), ("destination", .string(destination)),
                                                        ("mode", .string(modeName)),
                                                        ("note", .string("Maps opens after your reply. Keep the reply to one short sentence."))]))
            outcome.openAfterReply = url
            return outcome
        }
    }
}

struct RunShortcutTool: AssistantTool {
    let group = ToolGroup.shortcuts
    let spec = ToolSpec(
        name: "run_shortcut",
        description: "Run one of the user's Siri Shortcuts by its exact name (for things this app can't do directly, like Focus modes or smart home).",
        parameters: Schema.object([("name", Schema.string("Shortcut name, e.g. 'Work Focus'"))], required: ["name"]))

    func prepare(_ call: ToolCall) async throws -> PreparedAction {
        let name = (call["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ToolPreparationError.invalidArguments("Missing 'name'. Ask which shortcut to run.") }
        var comps = URLComponents(string: "shortcuts://run-shortcut")!
        comps.queryItems = [URLQueryItem(name: "name", value: name)]
        let url = comps.url!
        return PreparedAction(title: "Run shortcut", summary: name, icon: "square.stack.3d.up", requiresConfirmation: true) {
            var outcome = ToolOutcome(success: true, display: "Opening Shortcuts to run “\(name)”.",
                                      payload: .object([("status", .string("opening_shortcut")), ("name", .string(name)),
                                                        ("note", .string("Shortcuts opens after your reply. If no shortcut has that exact name, Shortcuts shows an error."))]))
            outcome.openAfterReply = url
            return outcome
        }
    }
}
