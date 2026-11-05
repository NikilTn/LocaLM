import Foundation
import llama

/// Timing and size numbers for one generation call.
struct GenerationStats: Codable, Equatable {
    var promptTokens = 0        // tokens in the full prompt
    var reusedTokens = 0        // prompt tokens already in the KV/recurrent cache (not re-processed)
    var generatedTokens = 0
    var promptMs: Double = 0    // time to process the new (non-reused) prompt tokens
    var ttftMs: Double = 0      // request start -> first sampled token
    var generationMs: Double = 0

    var promptTokensPerSec: Double {
        let n = Double(promptTokens - reusedTokens)
        return promptMs > 0 ? n / (promptMs / 1000) : 0
    }
    var generationTokensPerSec: Double {
        generationMs > 0 ? Double(generatedTokens) / (generationMs / 1000) : 0
    }
}

struct LoadedModelInfo: Codable, Equatable {
    var description: String
    var parameterCount: UInt64
    var sizeBytes: UInt64
    var contextSize: UInt32
    var loadMs: Double
    var isHybrid: Bool
}

enum LlamaError: LocalizedError {
    case modelLoadFailed(String)
    case contextInitFailed
    case notLoaded
    case promptTooLong(tokens: Int, limit: Int)
    case decodeFailed(Int32)
    case busy

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let p): return "Could not load model at \(p)."
        case .contextInitFailed: return "Could not create the inference context."
        case .notLoaded: return "No model is loaded."
        case .promptTooLong(let t, let l): return "Conversation is too long (\(t) tokens, limit \(l)). Clear the chat."
        case .decodeFailed(let rc): return "Inference failed (llama_decode returned \(rc))."
        case .busy: return "The model is already generating."
        }
    }
}

enum GenerationEvent {
    case text(String)
    case done(fullText: String, stats: GenerationStats)
}

/// Thin wrapper around the llama.cpp C API.
/// All llama.cpp calls run on one serial queue, so the C objects are never touched concurrently.
final class LlamaEngine: @unchecked Sendable {
    struct Sampling {
        var temperature: Float = 0.1      // Liquid's recommended settings for LFM3-1.7B
        var topK: Int32 = 50
        var repeatPenalty: Float = 1.1
        var repeatLastN: Int32 = 64
        var seed: UInt32 = UInt32(LLAMA_DEFAULT_SEED) // random; set a fixed value for reproducible evals
    }

    private let queue = DispatchQueue(label: "localm.llama", qos: .userInitiated)
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    /// Exactly the tokens that have been decoded into the context's memory, in order.
    private var cachedTokens: [llama_token] = []

    private let flagLock = NSLock()
    private var _cancelRequested = false
    private var _isGenerating = false

    private static let backendInit: Void = {
        llama_backend_init()
    }()

    var sampling = Sampling()

    deinit {
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
    }

    // MARK: Loading

    func load(path: String, contextSize: UInt32 = 8192) async throws -> LoadedModelInfo {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                _ = LlamaEngine.backendInit
                self.unloadLocked()
                let start = CFAbsoluteTimeGetCurrent()

                var mparams = llama_model_default_params()
                mparams.n_gpu_layers = 999 // offload every layer to Metal
                guard let m = llama_model_load_from_file(path, mparams) else {
                    cont.resume(throwing: LlamaError.modelLoadFailed(path)); return
                }

                var cparams = llama_context_default_params()
                cparams.n_ctx = contextSize
                cparams.n_batch = 512
                cparams.n_ubatch = 512
                let threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 2)))
                cparams.n_threads = threads
                cparams.n_threads_batch = threads
                guard let c = llama_init_from_model(m, cparams) else {
                    llama_model_free(m)
                    cont.resume(throwing: LlamaError.contextInitFailed); return
                }

                self.model = m
                self.ctx = c
                self.vocab = llama_model_get_vocab(m)
                self.cachedTokens = []

                var descBuf = [CChar](repeating: 0, count: 256)
                _ = llama_model_desc(m, &descBuf, descBuf.count)
                let info = LoadedModelInfo(
                    description: String(cString: descBuf),
                    parameterCount: llama_model_n_params(m),
                    sizeBytes: llama_model_size(m),
                    contextSize: llama_n_ctx(c),
                    loadMs: (CFAbsoluteTimeGetCurrent() - start) * 1000,
                    isHybrid: llama_model_is_hybrid(m) || llama_model_is_recurrent(m)
                )
                cont.resume(returning: info)
            }
        }
    }

    func unload() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.unloadLocked()
                cont.resume()
            }
        }
    }

    private func unloadLocked() {
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        ctx = nil; model = nil; vocab = nil
        cachedTokens = []
    }

    // MARK: Generation

    func cancel() {
        flagLock.lock(); _cancelRequested = true; flagLock.unlock()
    }

    private var cancelRequested: Bool {
        flagLock.lock(); defer { flagLock.unlock() }
        return _cancelRequested
    }

    /// Streams generated text for a fully rendered prompt (special tokens such as <|im_start|> are parsed).
    /// The prompt's longest prefix that is already in the cache is reused instead of re-processed.
    func generate(prompt: String, maxTokens: Int = 512) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            flagLock.lock()
            if _isGenerating {
                flagLock.unlock()
                continuation.finish(throwing: LlamaError.busy)
                return
            }
            _isGenerating = true
            _cancelRequested = false
            flagLock.unlock()

            queue.async {
                defer {
                    self.flagLock.lock(); self._isGenerating = false; self.flagLock.unlock()
                }
                do {
                    try self.runGeneration(prompt: prompt, maxTokens: maxTokens, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func runGeneration(prompt: String,
                               maxTokens: Int,
                               continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) throws {
        guard let ctx, let vocab else { throw LlamaError.notLoaded }
        let t0 = CFAbsoluteTimeGetCurrent()
        var stats = GenerationStats()

        let tokens = tokenize(prompt)
        stats.promptTokens = tokens.count
        let limit = Int(llama_n_ctx(ctx))
        if tokens.count + maxTokens > limit {
            throw LlamaError.promptTooLong(tokens: tokens.count, limit: limit - maxTokens)
        }

        // Reuse the cache only when it is an exact prefix of the new prompt. LFM3 is a hybrid
        // (convolution + attention) model, whose recurrent state cannot be partially rolled back,
        // so on any divergence we clear everything and re-process the prompt.
        var common = 0
        while common < cachedTokens.count, common < tokens.count, cachedTokens[common] == tokens[common] {
            common += 1
        }
        if common < cachedTokens.count || common == tokens.count {
            llama_memory_clear(llama_get_memory(ctx), true)
            cachedTokens = []
            common = 0
        }
        stats.reusedTokens = common

        // Prefill the new part of the prompt in n_batch chunks.
        let tPrefill = CFAbsoluteTimeGetCurrent()
        let batchSize = Int(llama_n_batch(ctx))
        var i = common
        while i < tokens.count {
            if cancelRequested { break }
            let end = min(i + batchSize, tokens.count)
            var chunk = Array(tokens[i..<end])
            let rc = chunk.withUnsafeMutableBufferPointer { buf in
                llama_decode(ctx, llama_batch_get_one(buf.baseAddress, Int32(buf.count)))
            }
            if rc != 0 {
                llama_memory_clear(llama_get_memory(ctx), true)
                cachedTokens = []
                throw LlamaError.decodeFailed(rc)
            }
            cachedTokens.append(contentsOf: chunk)
            i = end
        }
        // llama_decode is asynchronous on Metal; wait for the GPU so the prefill timing is real.
        llama_synchronize(ctx)
        stats.promptMs = (CFAbsoluteTimeGetCurrent() - tPrefill) * 1000

        let sampler = makeSampler(vocab: vocab)
        defer { llama_sampler_free(sampler) }

        var fullText = ""
        var pendingBytes: [UInt8] = []
        let tGen = CFAbsoluteTimeGetCurrent()

        if !cancelRequested {
            for step in 0..<maxTokens {
                if cancelRequested { break }
                let token = llama_sampler_sample(sampler, ctx, -1)
                if step == 0 { stats.ttftMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000 }
                if llama_vocab_is_eog(vocab, token) { break }
                stats.generatedTokens += 1

                pendingBytes.append(contentsOf: pieceBytes(token, vocab: vocab))
                let piece = Self.drainValidUTF8(&pendingBytes)
                if !piece.isEmpty {
                    fullText += piece
                    continuation.yield(.text(piece))
                }

                var next = token
                let rc = withUnsafeMutablePointer(to: &next) { ptr in
                    llama_decode(ctx, llama_batch_get_one(ptr, 1))
                }
                if rc != 0 {
                    llama_memory_clear(llama_get_memory(ctx), true)
                    cachedTokens = []
                    throw LlamaError.decodeFailed(rc)
                }
                cachedTokens.append(token)
            }
        }
        if !pendingBytes.isEmpty {
            let rest = String(decoding: pendingBytes, as: UTF8.self)
            fullText += rest
            continuation.yield(.text(rest))
        }
        stats.generationMs = (CFAbsoluteTimeGetCurrent() - tGen) * 1000
        continuation.yield(.done(fullText: fullText, stats: stats))
        continuation.finish()
    }

    private func makeSampler(vocab: OpaquePointer) -> UnsafeMutablePointer<llama_sampler> {
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        llama_sampler_chain_add(chain, llama_sampler_init_penalties(
            llama_vocab_n_tokens(vocab), sampling.repeatLastN, sampling.repeatPenalty, 0, 0))
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(sampling.topK))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(sampling.temperature))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(sampling.seed))
        return chain
    }

    // MARK: Tokens

    private func tokenize(_ text: String) -> [llama_token] {
        let byteCount = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(byteCount) + 16)
        // add_special=false: the prompt already starts with <|startoftext|> (as the chat template does).
        // parse_special=true: <|im_start|>, <tool_call>, ... become their special token ids.
        var n = llama_tokenize(vocab, text, byteCount, &tokens, Int32(tokens.count), false, true)
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, byteCount, &tokens, Int32(tokens.count), false, true)
        }
        return Array(tokens.prefix(Int(max(n, 0))))
    }

    /// Renders special tokens too, because LFM3 emits <tool_call>, <function=...> etc. as special tokens.
    private func pieceBytes(_ token: llama_token, vocab: OpaquePointer) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, true)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, true)
        }
        return buf.prefix(Int(max(n, 0))).map { UInt8(bitPattern: $0) }
    }

    /// Returns the longest valid UTF-8 prefix and keeps an incomplete trailing sequence for the next token.
    static func drainValidUTF8(_ bytes: inout [UInt8]) -> String {
        if bytes.isEmpty { return "" }
        for cut in 0...min(3, bytes.count) {
            let prefix = bytes[0..<(bytes.count - cut)]
            if let s = String(bytes: prefix, encoding: .utf8) {
                bytes.removeFirst(prefix.count)
                return s
            }
        }
        // Not recoverable as UTF-8: emit with replacement characters instead of stalling.
        let s = String(decoding: bytes, as: UTF8.self)
        bytes.removeAll()
        return s
    }
}
