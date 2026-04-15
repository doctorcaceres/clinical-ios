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
