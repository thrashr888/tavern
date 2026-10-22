import Foundation

/// A typed question for a decision model (Clef, Clef Flash, Jev): pick one option, or yes/no.
/// Decision models answer with a probability per option in one pass; they suggest, and a person
/// still decides. Ollama's `/v1/systemone` and TypeSafe's Jev share this contract, as in Alchemy.
public enum DecisionQuestion: Equatable, Sendable {
    /// Options are keys with an optional description the model reads.
    case choice(instructions: String, options: [(key: String, description: String?)])
    /// The answer is the probability of yes.
    case noul(instructions: String)

    public static func == (a: DecisionQuestion, b: DecisionQuestion) -> Bool {
        switch (a, b) {
        case let (.noul(x), .noul(y)): return x == y
        case let (.choice(x, xs), .choice(y, ys)):
            return x == y && xs.map(\.key) == ys.map(\.key) && xs.map(\.description) == ys.map(\.description)
        default: return false
        }
    }

    var json: JSONValue {
        switch self {
        case .noul(let instructions):
            return ["type": "noul", "instructions": .string(instructions)]
        case .choice(let instructions, let options):
            var criteria: [String: JSONValue] = [:]
            for option in options { criteria[option.key] = option.description.map(JSONValue.string) ?? .null }
            return ["type": "choice", "instructions": .string(instructions), "criteria": .object(criteria)]
        }
    }

    var optionKeys: [String] {
        if case .choice(_, let options) = self { return options.map(\.key) }
        return []
    }
}

public enum DecisionAnswer: Equatable, Sendable {
    /// `confidence` is the margin between the top two probabilities, one definition for every backend.
    case choice(String, probabilities: [String: Double], confidence: Double)
    case noul(Double)

    public var choice: String? { if case .choice(let key, _, _) = self { return key } else { return nil } }
    public var confidence: Double {
        switch self {
        case .choice(_, _, let confidence): return confidence
        case .noul(let p): return abs(p - 0.5) * 2
        }
    }
}

public struct DecisionError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Where decisions are asked: a local decision model through Ollama (no key), or Jev with a key.
public struct DecisionBackend: Equatable, Sendable {
    public var endpoint: URL
    public var model: String
    /// Jev's bearer key. Never logged or shown.
    public var key: String?

    public var isLocal: Bool { key == nil }
    public var label: String { isLocal ? "\(model) (local)" : "\(model) (TypeSafe)" }

    public init(endpoint: URL, model: String, key: String? = nil) {
        self.endpoint = endpoint
        self.model = model
        self.key = key
    }

    /// Local decision models in preference order (Alchemy's benchmarks): Clef Flash first.
    static let families = ["clef-flash", "clef", "nimble", "tev1"]
    public static let ollamaBase = URL(string: "http://127.0.0.1:11434")!
    static let jevEndpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    /// Pinned: thresholds tuned against one version should stay with it.
    static let jevModel = "jev-1.13.0"

    /// A local decision model if Ollama has one, else Jev if a key is set up, else nil.
    public static func best(ollama: URL = ollamaBase) async -> DecisionBackend? {
        if let local = await local(ollama: ollama) { return local }
        return jev()
    }

    /// The best installed tag Ollama marks with the `decision` capability. Any failure is "none".
    public static func local(ollama: URL = ollamaBase) async -> DecisionBackend? {
        guard let tags = try? await getJSON(ollama.appendingPathComponent("api/tags"))["models"]?.arrayValue else { return nil }
        var decision: [String] = []
        for name in tags.compactMap({ $0["name"]?.stringValue }) {
            // A tag Ollama can't read answers /api/show with an error: not a decision model, keep scanning.
            let shown = try? await postJSON(ollama.appendingPathComponent("api/show"), body: ["model": .string(name)], key: nil, timeout: 5)
            if shown?["capabilities"]?.arrayValue?.contains(where: { $0.stringValue == "decision" }) == true { decision.append(name) }
        }
        guard let model = pick(decision) else { return nil }
        return DecisionBackend(endpoint: ollama.appendingPathComponent("v1/systemone"), model: model)
    }

    /// The preferred family first; within a family the larger tag.
    static func pick(_ tags: [String]) -> String? {
        func family(_ tag: String) -> Int {
            let base = tag.split(separator: ":").first.map(String.init) ?? tag
            return families.firstIndex(of: base) ?? families.count
        }
        return tags.sorted { (family($0), $1) < (family($1), $0) }.first
    }

    /// Jev with the key Alchemy uses: TYPESAFE_API_KEY, the file TYPESAFE_API_KEY_FILE names, or
    /// ~/.config/typesafe/api-key.
    public static func jev(environment: [String: String] = ProcessInfo.processInfo.environment,
                           home: URL = TavernPaths.userHome) -> DecisionBackend? {
        var key = environment["TYPESAFE_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if key?.isEmpty ?? true {
            let files = [environment["TYPESAFE_API_KEY_FILE"].map { URL(fileURLWithPath: $0) },
                         home.appendingPathComponent(".config/typesafe/api-key")].compactMap { $0 }
            key = files.lazy.compactMap { try? String(contentsOf: $0, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && !$0.contains(where: \.isNewline) }
        }
        guard let key, !key.isEmpty else { return nil }
        return DecisionBackend(endpoint: jevEndpoint, model: jevModel, key: key)
    }

    /// Asks every question over `state` in one request. Throws when the answer doesn't match the
    /// questions, so a caller never acts on a malformed pick.
    public func ask(state: String, questions: [String: DecisionQuestion]) async throws -> [String: DecisionAnswer] {
        let body: JSONValue = [
            "model": .string(model),
            "state": .string(state),
            "questions": .object(questions.mapValues(\.json)),
        ]
        let raw = try await Self.postJSON(endpoint, body: body, key: key, timeout: isLocal ? 60 : 15)
        return try Self.parse(raw, questions: questions)
    }

    static func parse(_ raw: JSONValue, questions: [String: DecisionQuestion]) throws -> [String: DecisionAnswer] {
        guard let answers = raw["answers"] else { throw DecisionError("No answers in the decision model's reply") }
        var out: [String: DecisionAnswer] = [:]
        for (id, question) in questions {
            guard let answer = answers[id] else { throw DecisionError("The decision model skipped \(id)") }
            switch question {
            case .noul:
                guard answer["type"]?.stringValue == "noul", let p = answer["noul"]?.doubleValue, (0...1).contains(p) else {
                    throw DecisionError("Malformed yes/no answer for \(id)")
                }
                out[id] = .noul(p)
            case .choice:
                let keys = Set(question.optionKeys)
                var probabilities: [String: Double] = [:]
                if case .object(let values)? = answer["probabilities"] {
                    for (key, value) in values { probabilities[key] = value.doubleValue }
                }
                let total = probabilities.values.reduce(0, +)
                guard answer["type"]?.stringValue == "choice", let choice = answer["choice"]?.stringValue, keys.contains(choice),
                      Set(probabilities.keys) == keys, abs(total - 1) < 0.02 else {
                    throw DecisionError("Malformed choice answer for \(id)")
                }
                out[id] = .choice(choice, probabilities: probabilities, confidence: margin(probabilities.values))
            }
        }
        return out
    }

    static func margin<S: Sequence>(_ probabilities: S) -> Double where S.Element == Double {
        let top = probabilities.sorted(by: >)
        return max(0, min(1, (top.first ?? 0) - (top.dropFirst().first ?? 0)))
    }

    private static func getJSON(_ url: URL) async throws -> JSONValue {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DecisionError("\(url.path) failed") }
        return try JSONValue.decode(data)
    }

    private static func postJSON(_ url: URL, body: JSONValue, key: String?, timeout: TimeInterval) async throws -> JSONValue {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try body.encoded()
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw DecisionError("Decision model answered HTTP \(status)") }
        return try JSONValue.decode(data)
    }
}

/// Tavern's suggestion questions. Each choice offers at most 12 options plus a way out ("none"):
/// Alchemy saw 9B decision models fall to about half right when scoring 24 at once.
public enum DecisionSuggestions {
    public typealias Option = (key: String, description: String?)
    public static let maxOptions = 12
    public static let none = "none"
    /// Below this margin Tavern shows nothing.
    public static let minConfidence = 0.7

    /// Which spell fits a task: one question per batch of 12 spells.
    public static func spellQuestions(for spells: [Spell]) -> [String: DecisionQuestion] {
        var questions: [String: DecisionQuestion] = [:]
        for (index, start) in stride(from: 0, to: spells.count, by: maxOptions).enumerated() {
            let batch = spells[start..<min(start + maxOptions, spells.count)]
            var options: [Option] = batch.map { (key: $0.id, description: Optional($0.description)) }
            options.append((key: none, description: "No playbook fits"))
            questions["spell\(index)"] = .choice(
                instructions: "Which of these playbooks should be followed for the task in the state? Pick none if no playbook clearly fits.",
                options: options)
        }
        return questions
    }

    /// The most likely spell across the batches, if one is confident enough.
    public static func spell(from answers: [String: DecisionAnswer], minConfidence: Double = minConfidence) -> (id: String, confidence: Double)? {
        answers.values.compactMap { answer -> (String, Double)? in
            guard case .choice(let key, _, let confidence) = answer, key != none, confidence >= minConfidence else { return nil }
            return (key, confidence)
        }.max { $0.1 < $1.1 }.map { (id: $0.0, confidence: $0.1) }
    }

    /// Who a ticket is for and which project it belongs to, asked together.
    public static func ticketQuestions(members: [RosterMember], projects: [(id: String, name: String)]) -> [String: DecisionQuestion] {
        var questions: [String: DecisionQuestion] = [:]
        var people: [Option] = members.prefix(maxOptions).map { member -> Option in
            let about = [member.name, member.partyClass, member.summary, member.owns.map { "owns \($0.joined(separator: ", "))" }]
            return (key: member.id, description: Optional(about.compactMap { $0 }.joined(separator: " · ")))
        }
        if !people.isEmpty {
            people.append((key: none, description: "Unclear"))
            questions["agent"] = .choice(instructions: "Which party member should take the ticket in the state? Pick none if it's unclear.",
                                         options: people)
        }
        var named: [Option] = projects.prefix(maxOptions).map { (key: $0.id, description: Optional($0.name)) }
        if !named.isEmpty {
            named.append((key: none, description: "Unclear"))
            questions["project"] = .choice(instructions: "Which project does the ticket in the state belong to? Pick none if it's unclear.",
                                           options: named)
        }
        return questions
    }

    /// A confident pick for one question, never "none".
    public static func pick(_ id: String, in answers: [String: DecisionAnswer], minConfidence: Double = minConfidence) -> String? {
        guard let answer = answers[id], let key = answer.choice, key != none, answer.confidence >= minConfidence else { return nil }
        return key
    }

    /// Logged for every suggestion, so the Friday review can see whether they help.
    public static let eventKind = "tavern.decision"

    public static func event(site: String, backend: DecisionBackend, answers: [String: DecisionAnswer], latency: TimeInterval,
                             date: Date = Date()) -> TavernEvent {
        var picked: [String: JSONValue] = [:]
        for (id, answer) in answers {
            picked[id] = ["choice": answer.choice.map(JSONValue.string) ?? .null, "confidence": .number(answer.confidence)]
        }
        let payload: JSONValue = ["type": "tavern_decision", "site": .string(site), "model": .string(backend.label),
                                  "latencyMs": .number((latency * 1000).rounded()), "answers": .object(picked)]
        return TavernEvent(source: EventSource.tavern, sourceID: "decision:\(UUID().uuidString)", threadKey: "decisions",
                           sourceTS: date, receivedTS: date, kind: eventKind, payload: (try? payload.encoded()) ?? Data())
    }
}

extension DecisionSuggestions {
    /// One question's options by probability, "none" left out, for chips with numbers and "Did you mean".
    public static func ranked(_ id: String, in answers: [String: DecisionAnswer]) -> [(key: String, probability: Double)] {
        guard case .choice(_, let probabilities, _)? = answers[id] else { return [] }
        return probabilities.filter { $0.key != none }.map { (key: $0.key, probability: $0.value) }
            .sorted { $0.probability > $1.probability }
    }
}
