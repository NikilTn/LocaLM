import Foundation

/// A downloadable model that has been checked to work with this app's prompt format and llama.cpp build.
struct ModelEntry: Identifiable, Equatable {
    var id: String { fileName }
    var displayName: String
    var fileName: String
    var url: URL
    var sizeBytes: Int64
    var sha256: String
    var note: String

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

enum ModelCatalog {
    /// Sizes and SHA-256 values from the Hugging Face API for LiquidAI/LFM3-1.7B-GGUF (main branch, Oct 2026).
    static let entries: [ModelEntry] = [
        ModelEntry(
            displayName: "LFM3 1.7B · Q4_0 QAD",
            fileName: "LFM3-1.7B-QAD-Q4_0.gguf",
            url: URL(string: "https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF/resolve/main/LFM3-1.7B-QAD-Q4_0.gguf")!,
            sizeBytes: 1_049_615_680,
            sha256: "43a7d09a0e9cba91b63eb7052488b9564569bddfd65754d2e426465e572a7452",
            note: "Recommended. 4-bit, trained to recover quantization loss."),
        ModelEntry(
            displayName: "LFM3 1.7B · Q8_0",
            fileName: "LFM3-1.7B-Q8_0.gguf",
            url: URL(string: "https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF/resolve/main/LFM3-1.7B-Q8_0.gguf")!,
            sizeBytes: 1_846_238_496,
            sha256: "8f6b24182258205e9e01e21f1f24a1f208c1e8115578825d202ce39976af20b6",
            note: "8-bit. Larger and slower, closer to full precision."),
    ]

    static var recommended: ModelEntry { entries[0] }
}
