import SwiftUI

// MARK: - Colors (from spec)
enum C {
    static let bg          = Color(hex: 0x0A0A0A)
    static let surface     = Color(hex: 0x111111)
    static let border      = Color(hex: 0x1A1A1A)
    static let borderPri   = Color(hex: 0x333333)
    static let borderSec   = Color(hex: 0x222222)
    static let text        = Color(hex: 0xFAFAFA)
    static let textSec     = Color(hex: 0xCCCCCC)
    static let textMuted   = Color(hex: 0x888888)
    static let textDim     = Color(hex: 0x555555)
    static let textDark    = Color(hex: 0x444444)
    static let accent      = Color(hex: 0x00CFA0)
    static let accentBg    = Color(hex: 0x00CFA0).opacity(0.08)
    static let error       = Color(hex: 0xFF4444)
    static let errorBg     = Color(hex: 0xFF4444).opacity(0.08)
    static let warning     = Color(hex: 0xFF9F43)
    static let warningBg   = Color(hex: 0xFF9F43).opacity(0.08)
}

// MARK: - API endpoints + Supabase (MUST match web app)
enum API {
    static let vercelBase   = "https://clinical-app-ten.vercel.app"
    static let supabaseURL  = "https://rtrzaketgvdggdfhedsn.supabase.co"
    static let supabaseKey  = "sb_publishable_zPQZ7Zl03zjS_uqvsNb-ug_JzgohYw2"
}

// MARK: - Note section ordering (matches generate-note.js exactly)
let newPatientSections = [
    "Chief Concern", "History of Present Illness", "Review of Systems",
    "Past Medical History", "Family History", "Birth History",
    "Developmental History", "Social History", "Assessment", "Plan",
]
let followUpSections = [
    "Date of Last Visit", "Summary from Last Visit",
    "Interval History", "Assessment", "Plan",
]
