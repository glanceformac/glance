import AppKit
import SwiftUI
import Observation

// MARK: feat/productivity - Calculator, unit and currency conversion

// MARK: Expression parser (recursive descent, no eval, no JavaScript)

struct CalcParser {
    enum Failure: Error { case syntax(String), math(String) }

    private var c: [Character]
    private var i = 0
    let ans: Double
    let degrees: Bool

    init(_ text: String, ans: Double, degrees: Bool) {
        // Thousands separators ("1,000") are dropped; operators are normalised.
        var t = text.replacingOccurrences(of: #"(?<=\d),(?=\d{3}(\D|$))"#, with: "", options: .regularExpression)
        for (a, b) in [("×", "*"), ("÷", "/"), ("−", "-"), ("–", "-"), ("—", "-"), ("**", "^"), ("π", "pi"), ("√", "sqrt ")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        c = Array(t)
        self.ans = ans
        self.degrees = degrees
    }

    static func evaluate(_ text: String, ans: Double = 0, degrees: Bool = false) throws -> Double {
        var p = CalcParser(text, ans: ans, degrees: degrees)
        p.skip()
        guard !p.atEnd else { throw Failure.syntax("empty") }
        let v = try p.expression().value
        p.skip()
        guard p.atEnd else { throw Failure.syntax("unexpected \(p.c[p.i])") }
        guard v.isFinite else { throw Failure.math("not a number") }
        return v
    }

    private var atEnd: Bool { i >= c.count }
    private mutating func skip() { while i < c.count, c[i] == " " || c[i] == "\t" { i += 1 } }
    private func peek() -> Character? { i < c.count ? c[i] : nil }

    /// A value, and whether it was written as a percentage ("10%"), so `200 + 10%` means 200 + 20.
    private struct V { var value: Double; var percent = false }

    private mutating func expression() throws -> V {
        var left = try term()
        while true {
            skip()
            guard let ch = peek(), ch == "+" || ch == "-" else { break }
            i += 1
            let right = try term()
            let delta = right.percent ? left.value * right.value : right.value
            left = V(value: ch == "+" ? left.value + delta : left.value - delta)
        }
        return left
    }

    private mutating func term() throws -> V {
        var left = try unary()
        while true {
            skip()
            guard let ch = peek() else { break }
            if ch == "*" {
                i += 1; left = V(value: left.value * (try unary()).value)
            } else if ch == "/" {
                i += 1
                let r = try unary().value
                guard r != 0 else { throw Failure.math("divide by zero") }
                left = V(value: left.value / r)
            } else if ch == "%", moduloFollows() {
                i += 1
                let r = try unary().value
                guard r != 0 else { throw Failure.math("divide by zero") }
                left = V(value: left.value.truncatingRemainder(dividingBy: r))
            } else if matchWord("of") {
                // "15% of 80"
                left = V(value: left.value * (try unary()).value)
            } else if matchWord("mod") {
                let r = try unary().value
                guard r != 0 else { throw Failure.math("divide by zero") }
                left = V(value: left.value.truncatingRemainder(dividingBy: r))
            } else if ch == "(" {
                // Implicit multiplication: 2(3+4)
                left = V(value: left.value * (try unary()).value)
            } else { break }
        }
        return left
    }

    /// "10 % 3" is modulo; "10%" or "10% + 2" is a percentage.
    private func moduloFollows() -> Bool {
        var j = i + 1
        while j < c.count, c[j] == " " { j += 1 }
        guard j < c.count else { return false }
        return c[j].isNumber || c[j] == "(" || c[j] == "."
    }

    private mutating func matchWord(_ w: String) -> Bool {
        let chars = Array(w)
        guard i + chars.count <= c.count, Array(c[i..<i + chars.count]) == chars else { return false }
        let after = i + chars.count
        if after < c.count, c[after].isLetter { return false }
        i = after
        return true
    }

    private mutating func power() throws -> V {
        let base = try postfix()
        skip()
        if peek() == "^" {
            i += 1
            let e = try unary()   // right associative, allows 2^-1
            let r = pow(base.value, e.value)
            guard r.isFinite else { throw Failure.math("overflow") }
            return V(value: r)
        }
        return base
    }

    private mutating func unary() throws -> V {
        skip()
        if peek() == "-" { i += 1; var v = try unary(); v.value = -v.value; return v }
        if peek() == "+" { i += 1; return try unary() }
        return try power()
    }

    private mutating func postfix() throws -> V {
        var v = try primary()
        while true {
            skip()
            if peek() == "%", !moduloFollows() { i += 1; v = V(value: v.value / 100, percent: true) }
            else if peek() == "!" {
                i += 1
                guard v.value >= 0, v.value <= 170, v.value == v.value.rounded() else { throw Failure.math("factorial") }
                v = V(value: v.value < 2 ? 1 : (2...Int(v.value)).reduce(1.0) { $0 * Double($1) })
            } else { break }
        }
        return v
    }

    private mutating func primary() throws -> V {
        skip()
        guard let ch = peek() else { throw Failure.syntax("unexpected end") }
        if ch == "(" {
            i += 1
            let v = try expression()
            skip()
            guard peek() == ")" else { throw Failure.syntax("missing )") }
            i += 1
            return V(value: v.value)
        }
        if ch.isNumber || ch == "." { return V(value: try number()) }
        if ch.isLetter {
            var name = ""
            while let n = peek(), n.isLetter || n.isNumber && !name.isEmpty { name.append(n); i += 1 }
            name = name.lowercased()
            switch name {
            case "pi": return V(value: .pi)
            case "e": return V(value: M_E)
            case "tau": return V(value: 2 * .pi)
            case "phi": return V(value: (1 + 5.0.squareRoot()) / 2)
            case "ans": return V(value: ans)
            default: break
            }
            skip()
            let arg: Double
            if peek() == "(" {
                i += 1
                arg = try expression().value
                skip()
                guard peek() == ")" else { throw Failure.syntax("missing )") }
                i += 1
            } else {
                arg = try power().value   // "sqrt 16"
            }
            return V(value: try apply(name, arg))
        }
        throw Failure.syntax("unexpected \(ch)")
    }

    private mutating func number() throws -> Double {
        var s = ""
        while let n = peek(), n.isNumber || n == "." { s.append(n); i += 1 }
        if let e = peek(), e == "e" || e == "E" {
            var j = i + 1
            if j < c.count, c[j] == "+" || c[j] == "-" { j += 1 }
            if j < c.count, c[j].isNumber {
                s.append("e")
                i += 1
                while i < j { s.append(c[i]); i += 1 }
                while let n = peek(), n.isNumber { s.append(n); i += 1 }
            }
        }
        guard let v = Double(s) else { throw Failure.syntax("bad number") }
        return v
    }

    private func apply(_ f: String, _ x: Double) throws -> Double {
        let rad = degrees ? x * .pi / 180 : x
        func back(_ r: Double) -> Double { degrees ? r * 180 / .pi : r }
        switch f {
        case "sin": return sin(rad)
        case "cos": return cos(rad)
        case "tan": return tan(rad)
        case "asin": guard abs(x) <= 1 else { throw Failure.math("asin") }; return back(asin(x))
        case "acos": guard abs(x) <= 1 else { throw Failure.math("acos") }; return back(acos(x))
        case "atan": return back(atan(x))
        case "sinh": return sinh(x)
        case "cosh": return cosh(x)
        case "tanh": return tanh(x)
        case "sqrt": guard x >= 0 else { throw Failure.math("sqrt of negative") }; return x.squareRoot()
        case "cbrt": return cbrt(x)
        case "ln": guard x > 0 else { throw Failure.math("ln") }; return log(x)
        case "log", "log10": guard x > 0 else { throw Failure.math("log") }; return log10(x)
        case "log2": guard x > 0 else { throw Failure.math("log") }; return log2(x)
        case "exp": return exp(x)
        case "abs": return abs(x)
        case "round": return x.rounded()
        case "floor": return floor(x)
        case "ceil": return ceil(x)
        case "fact": return try CalcParser.evaluate("\(x)!")
        default: throw Failure.syntax("unknown \(f)")
        }
    }
}

// MARK: Units

struct CalcUnit {
    enum Kind: String { case length, mass, temperature, time, data }
    let kind: Kind
    let name: String
    let aliases: [String]
    let factor: Double          // to the base unit of its kind (m, kg, s, byte); unused for temperature
}

enum CalcUnits {
    static let all: [CalcUnit] = {
        var u: [CalcUnit] = []
        func add(_ k: CalcUnit.Kind, _ name: String, _ f: Double, _ aliases: [String]) {
            u.append(CalcUnit(kind: k, name: name, aliases: aliases, factor: f))
        }
        // length (base metre)
        add(.length, "m", 1, ["m", "meter", "meters", "metre", "metres"])
        add(.length, "km", 1000, ["km", "kilometer", "kilometers", "kilometre", "kilometres"])
        add(.length, "cm", 0.01, ["cm", "centimeter", "centimeters", "centimetre", "centimetres"])
        add(.length, "mm", 0.001, ["mm", "millimeter", "millimeters", "millimetre", "millimetres"])
        add(.length, "µm", 1e-6, ["µm", "um", "micrometre", "micrometer", "micron", "microns"])
        add(.length, "nm", 1e-9, ["nm", "nanometre", "nanometer", "nanometres", "nanometers"])
        add(.length, "mi", 1609.344, ["mi", "mile", "miles"])
        add(.length, "yd", 0.9144, ["yd", "yds", "yard", "yards"])
        add(.length, "ft", 0.3048, ["ft", "foot", "feet"])
        add(.length, "in", 0.0254, ["in", "inch", "inches"])
        add(.length, "nmi", 1852, ["nmi", "nauticalmile", "nauticalmiles"])
        // mass (base kilogram)
        add(.mass, "kg", 1, ["kg", "kilo", "kilos", "kilogram", "kilograms"])
        add(.mass, "g", 0.001, ["g", "gram", "grams"])
        add(.mass, "mg", 1e-6, ["mg", "milligram", "milligrams"])
        add(.mass, "µg", 1e-9, ["µg", "ug", "microgram", "micrograms"])
        add(.mass, "lb", 0.45359237, ["lb", "lbs", "pound", "pounds"])
        add(.mass, "oz", 0.028349523125, ["oz", "ounce", "ounces"])
        add(.mass, "st", 6.35029318, ["st", "stone", "stones"])
        add(.mass, "t", 1000, ["t", "tonne", "tonnes"])
        // time (base second)
        add(.time, "µs", 1e-6, ["µs", "us", "microsecond", "microseconds"])
        add(.time, "ms", 0.001, ["ms", "millisecond", "milliseconds"])
        add(.time, "s", 1, ["s", "sec", "secs", "second", "seconds"])
        add(.time, "min", 60, ["min", "mins", "minute", "minutes"])
        add(.time, "h", 3600, ["h", "hr", "hrs", "hour", "hours"])
        add(.time, "d", 86400, ["d", "day", "days"])
        add(.time, "wk", 604800, ["wk", "wks", "week", "weeks"])
        add(.time, "mo", 2629800, ["mo", "month", "months"])
        add(.time, "yr", 31557600, ["yr", "yrs", "year", "years"])
        // data (base byte). Decimal like Finder (1 MB = 1,000,000 B); binary as KiB, MiB...
        add(.data, "bit", 0.125, ["bit", "bits", "b"])
        add(.data, "B", 1, ["B", "byte", "bytes"])
        add(.data, "KB", 1e3, ["kb", "kilobyte", "kilobytes"])
        add(.data, "MB", 1e6, ["mb", "megabyte", "megabytes"])
        add(.data, "GB", 1e9, ["gb", "gigabyte", "gigabytes"])
        add(.data, "TB", 1e12, ["tb", "terabyte", "terabytes"])
        add(.data, "PB", 1e15, ["pb", "petabyte", "petabytes"])
        add(.data, "KiB", 1024, ["kib", "kibibyte"])
        add(.data, "MiB", 1_048_576, ["mib", "mebibyte"])
        add(.data, "GiB", 1_073_741_824, ["gib", "gibibyte"])
        add(.data, "TiB", 1_099_511_627_776, ["tib", "tebibyte"])
        add(.data, "Kbit", 125, ["kbit", "kilobit", "kilobits"])
        add(.data, "Mbit", 125_000, ["mbit", "megabit", "megabits"])
        add(.data, "Gbit", 125_000_000, ["gbit", "gigabit", "gigabits"])
        // temperature handled separately
        add(.temperature, "°C", 1, ["c", "°c", "celsius", "centigrade"])
        add(.temperature, "°F", 1, ["f", "°f", "fahrenheit"])
        add(.temperature, "K", 1, ["k", "kelvin"])
        return u
    }()

    static func find(_ raw: String) -> CalcUnit? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s == "B" { return all.first { $0.name == "B" } }   // exact case: B is byte, b is bit
        let l = s.lowercased()
        return all.first { $0.aliases.contains(l) }
    }

    static func convert(_ v: Double, from: CalcUnit, to: CalcUnit) -> Double? {
        guard from.kind == to.kind else { return nil }
        if from.kind == .temperature {
            let c: Double
            switch from.name { case "°C": c = v; case "°F": c = (v - 32) * 5 / 9; default: c = v - 273.15 }
            switch to.name { case "°C": return c; case "°F": return c * 9 / 5 + 32; default: return c + 273.15 }
        }
        return v * from.factor / to.factor
    }
}

// MARK: Currency (open.er-api.com: free, no key; updates once a day, so we cache for 24 h)

@Observable @MainActor
final class CurrencyRates {
    static let shared = CurrencyRates()
    struct Cache: Codable { var base = "USD"; var rates: [String: Double] = [:]; var fetched = Date.distantPast; var providerUpdate = "" }
    private(set) var cache = Cache()
    private(set) var status = ""
    private(set) var loading = false
    /// Debug/testing: pretend the network is down.
    var simulateOffline = false
    @ObservationIgnored private var loaded = false

    var rates: [String: Double] { loadIfNeeded(); return cache.rates }
    var isStale: Bool { Date().timeIntervalSince(cache.fetched) > 24 * 3600 }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let c = ToolsStore.read(Cache.self, "rates.json") { cache = c }
        updateStatus()
    }

    func refreshIfNeeded(force: Bool = false) {
        loadIfNeeded()
        guard force || cache.rates.isEmpty || isStale, !loading else { return }
        loading = true
        let offline = simulateOffline
        Task {
            let result = await Self.fetch(offline: offline)
            loading = false
            if let r = result {
                cache = Cache(base: "USD", rates: r.rates, fetched: Date(), providerUpdate: r.updated)
                if let d = try? JSONEncoder().encode(cache) { ToolsStore.write(d, to: ToolsStore.url("rates.json")) }
            }
            updateStatus(failed: result == nil)
        }
    }

    private func updateStatus(failed: Bool = false) {
        if cache.rates.isEmpty { status = failed ? "No rates yet (offline)" : "Rates not loaded"; return }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        status = (failed ? "Offline, using rates from " : "Rates from ") + f.string(from: cache.fetched)
    }

    nonisolated private static func fetch(offline: Bool) async -> (rates: [String: Double], updated: String)? {
        if offline { return nil }
        guard let url = URL(string: "https://open.er-api.com/v6/latest/USD") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Glance", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["result"] as? String) == "success",
              let rates = obj["rates"] as? [String: Double], rates.count > 20 else { return nil }
        return (rates, obj["time_last_update_utc"] as? String ?? "")
    }
}

// MARK: Engine: expression, unit conversion or currency conversion

enum CalcOutcome: Equatable {
    case value(Double, display: String)
    case conversion(display: String, copy: String, isCurrency: Bool)
    case error(String)
    case empty
}

enum CalcEngine {
    static let currencySymbols: [Character: String] = ["$": "USD", "£": "GBP", "€": "EUR", "¥": "JPY", "₹": "INR"]

    static func format(_ v: Double, maxDigits: Int = 10) -> String {
        if v == 0 { return "0" }
        let a = abs(v)
        if a >= 1e15 || a < 1e-9 {
            return String(format: "%.8e", v).replacingOccurrences(of: #"\.?0+e"#, with: "e", options: .regularExpression)
        }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = a >= 1000 ? 4 : maxDigits
        f.usesGroupingSeparator = true
        f.locale = Locale(identifier: "en_GB")
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    static func plain(_ v: Double) -> String {
        let s = String(format: "%.10g", v)
        return s
    }

    static func evaluate(_ raw: String, ans: Double, degrees: Bool, rates: [String: Double]) -> CalcOutcome {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .empty }
        if let conv = convert(q, ans: ans, degrees: degrees, rates: rates) { return conv }
        do {
            let v = try CalcParser.evaluate(q, ans: ans, degrees: degrees)
            return .value(v, display: format(v))
        } catch CalcParser.Failure.math(let m) {
            return .error(m)
        } catch {
            return .error("")   // incomplete input while typing: stay quiet
        }
    }

    /// "5 ft in cm", "20 c to f", "100 usd to gbp", "$50 to eur", "2 GB to MB"
    private static func convert(_ q: String, ans: Double, degrees: Bool, rates: [String: Double]) -> CalcOutcome? {
        let lower = q.lowercased()
        var leftS = "", rightS = ""
        var found = false
        for sep in [" to ", "->", "→", " into ", " as ", " in "] {
            if let r = lower.range(of: sep, options: .backwards) {
                leftS = String(q[q.startIndex..<q.index(q.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: r.lowerBound))])
                rightS = String(q[q.index(q.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: r.upperBound))...])
                found = true
                break
            }
        }
        guard found else { return nil }
        leftS = leftS.trimmingCharacters(in: .whitespaces)
        rightS = rightS.trimmingCharacters(in: .whitespaces)
        guard !leftS.isEmpty, !rightS.isEmpty else { return nil }

        // Source: optional leading currency symbol, number/expression, trailing unit/code.
        var fromToken = ""
        var numberPart = leftS
        if let first = leftS.first, let code = currencySymbols[first] {
            fromToken = code
            numberPart = String(leftS.dropFirst())
        } else if let m = leftS.range(of: #"\s*[A-Za-z°µ]+$"#, options: .regularExpression) {
            fromToken = leftS[m].trimmingCharacters(in: .whitespaces)
            numberPart = String(leftS[leftS.startIndex..<m.lowerBound])
        } else { return nil }
        let toToken = rightS.trimmingCharacters(in: CharacterSet(charactersIn: ". "))

        var amount = 1.0
        if !numberPart.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let v = try? CalcParser.evaluate(numberPart, ans: ans, degrees: degrees) else { return nil }
            amount = v
        }

        // Units first (they never clash with 3-letter currency codes in practice).
        if let f = CalcUnits.find(fromToken), let t = CalcUnits.find(toToken) {
            guard let out = CalcUnits.convert(amount, from: f, to: t) else {
                return .error("Cannot convert \(f.kind.rawValue) to \(t.kind.rawValue)")
            }
            let disp = "\(format(amount)) \(f.name) = \(format(out)) \(t.name)"
            return .conversion(display: disp, copy: plain(out), isCurrency: false)
        }
        let fc = fromToken.uppercased(), tc = toToken.uppercased()
        let looksCurrency = fc.count == 3 && tc.count == 3
        if looksCurrency {
            guard !rates.isEmpty else { return .error("Currency rates are not loaded yet") }
            guard let rf = rates[fc], let rt = rates[tc], rf > 0 else { return .error("Unknown currency") }
            let out = amount * rt / rf
            let digits = abs(out) >= 1 ? 2 : 4
            let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = digits; f.minimumFractionDigits = digits
            f.locale = Locale(identifier: "en_GB")
            let disp = "\(format(amount)) \(fc) = \(f.string(from: NSNumber(value: out)) ?? "\(out)") \(tc)"
            return .conversion(display: disp, copy: String(format: "%.\(digits)f", out), isCurrency: true)
        }
        if CalcUnits.find(fromToken) != nil || CalcUnits.find(toToken) != nil { return .error("Unknown unit") }
        return nil
    }
}

// MARK: View

struct CalcEntry: Identifiable { let id = UUID(); let input: String; let output: String; let copy: String }

@Observable @MainActor
final class CalcState {
    static let shared = CalcState()
    var input = ""
    var ans = 0.0
    var degrees = false
    var history: [CalcEntry] = []
}

struct CalculatorView: View {
    let theme: Theme
    private let st = CalcState.shared
    private let rates = CurrencyRates.shared
    @FocusState private var focused: Bool
    @State private var copied: UUID?

    private var outcome: CalcOutcome {
        CalcEngine.evaluate(st.input, ans: st.ans, degrees: st.degrees, rates: rates.rates)
    }

    var body: some View {
        let out = outcome
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ToolField(theme: theme, placeholder: "Try 12% of 80, sqrt(2)*ans, 5 ft in cm, 20 c to f, 100 usd to gbp",
                          text: Bindable(st).input, symbol: "equal", focus: $focused) { commit(out) }
                ToolPill(theme: theme, title: st.degrees ? "DEG" : "RAD") { st.degrees.toggle() }
                    .help("Angle unit for sin, cos, tan")
            }
            resultLine(out)
            HStack {
                Text("History").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.tertiary)
                Spacer()
                Text("ans = \(CalcEngine.format(st.ans))").font(.system(size: 10).monospacedDigit()).foregroundStyle(theme.tertiary)
                if !st.history.isEmpty {
                    Button { st.history.removeAll() } label: { Text("Clear").font(.system(size: 10)).foregroundStyle(theme.secondary) }.buttonStyle(.plain)
                }
            }
            ScrollView {
                LazyVStack(spacing: 3) {
                    if st.history.isEmpty {
                        Text("Press Return to keep a result. \"ans\" is the last one. Click a row to copy it.")
                            .font(.system(size: 11)).foregroundStyle(theme.tertiary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    ForEach(st.history) { e in
                        Button {
                            copy(e.copy)
                            copied = e.id
                        } label: {
                            HStack {
                                Text(e.input).font(.system(size: 12)).foregroundStyle(theme.secondary).lineLimit(1)
                                Spacer()
                                Text(copied == e.id ? "Copied" : e.output).font(.system(size: 12, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(copied == e.id ? theme.accent : theme.primary).lineLimit(1)
                            }
                            .padding(.horizontal, 10).frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.card))
                        }.buttonStyle(.plain)
                    }
                }
            }
            if !rates.status.isEmpty {
                HStack(spacing: 6) {
                    Text("Currency: \(rates.status) · open.er-api.com").font(.system(size: 9)).foregroundStyle(theme.tertiary)
                    Button { rates.refreshIfNeeded(force: true) } label: { Image(systemName: "arrow.clockwise").font(.system(size: 9)) }
                        .buttonStyle(.plain).foregroundStyle(theme.secondary).help("Refresh rates now")
                }
            }
        }
        .onAppear { focused = true; rates.refreshIfNeeded() }
    }

    @ViewBuilder private func resultLine(_ out: CalcOutcome) -> some View {
        HStack {
            switch out {
            case .empty: Text(" ").font(.system(size: 22, weight: .light))
            case .error(let m):
                Text(m.isEmpty ? "…" : m).font(.system(size: 13)).foregroundStyle(m.isEmpty ? theme.tertiary : .orange).frame(height: 28, alignment: .leading)
            case .value(_, let d): Text("= " + d).font(.system(size: 22, weight: .light).monospacedDigit()).foregroundStyle(theme.primary).lineLimit(1).minimumScaleFactor(0.5)
            case .conversion(let d, _, _): Text(d).font(.system(size: 18, weight: .light).monospacedDigit()).foregroundStyle(theme.primary).lineLimit(1).minimumScaleFactor(0.5)
            }
            Spacer()
        }
        .frame(height: 30)
    }

    private func commit(_ out: CalcOutcome) {
        switch out {
        case .value(let v, let d):
            st.history.insert(CalcEntry(input: st.input, output: d, copy: CalcEngine.plain(v)), at: 0)
            st.ans = v
        case .conversion(let d, let c, _):
            st.history.insert(CalcEntry(input: st.input, output: d, copy: c), at: 0)
            if let v = Double(c) { st.ans = v }
        default: return
        }
        if st.history.count > 30 { st.history.removeLast() }
        st.input = ""
    }

    private func copy(_ s: String) {
        let pb = Env.pasteboard
        pb.clearContents()
        pb.setString(s, forType: .string)
        ClipboardStore.shared.noteOwnWrite()
    }
}
