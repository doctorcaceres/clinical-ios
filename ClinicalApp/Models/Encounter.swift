import Foundation

struct Encounter: Codable, Identifiable, Hashable {
    let id: String
    var encounterType: String
    var transcript: String?
    var originalNote: [String: String]?
    var finalNote: [String: String]?
    var doctorInstructions: String?
    var elapsed: Int?
    var status: String
    var createdAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case encounterType = "encounter_type"
        case transcript
        case originalNote = "original_note"
        case finalNote = "final_note"
        case doctorInstructions = "doctor_instructions"
        case elapsed, status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        encounterType = try c.decode(String.self, forKey: .encounterType)
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript)
        originalNote = Encounter.decodeFlexibleJSON(c, key: .originalNote)
        finalNote = Encounter.decodeFlexibleJSON(c, key: .finalNote)
        doctorInstructions = try c.decodeIfPresent(String.self, forKey: .doctorInstructions)
        elapsed = try c.decodeIfPresent(Int.self, forKey: .elapsed)
        status = try c.decode(String.self, forKey: .status)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(encounterType, forKey: .encounterType)
        try c.encodeIfPresent(transcript, forKey: .transcript)
        try c.encodeIfPresent(originalNote, forKey: .originalNote)
        try c.encodeIfPresent(finalNote, forKey: .finalNote)
        try c.encodeIfPresent(doctorInstructions, forKey: .doctorInstructions)
        try c.encodeIfPresent(elapsed, forKey: .elapsed)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }

    /// Notes can come from Supabase in two shapes:
    /// 1. A proper jsonb object: `{"Chief Concern": "..."}`
    /// 2. A JSON-encoded string (legacy bug): `"{\"Chief Concern\": \"...\"}"`
    /// This decoder tolerates both so existing rows don't break the list fetch.
    private static func decodeFlexibleJSON(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> [String: String]? {
        // Try as dictionary first
        if let dict = try? c.decode([String: String].self, forKey: key) {
            return dict
        }
        // Fallback: the value is stored as a JSON-encoded string
        if let str = try? c.decode(String.self, forKey: key),
           let data = str.data(using: .utf8),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            return dict
        }
        return nil
    }

    var displayType: String {
        encounterType == "new" ? "New Patient" :
        encounterType == "followup" ? "Follow Up" : encounterType.capitalized
    }

    var displayDate: String {
        guard let iso = createdAt else { return "" }
        return formatDate(iso)
    }

    var chiefConcern: String? {
        let note = finalNote ?? originalNote
        return note?["Chief Concern"] ?? note?["CHIEF CONCERN"]
    }

    var isProcessing: Bool { status == "processing" || status == "recording" }
    var isError: Bool { status == "error" }
    var isFinalized: Bool { status == "finalized" }
    var hasNote: Bool { originalNote != nil || finalNote != nil }

    static func == (lhs: Encounter, rhs: Encounter) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
