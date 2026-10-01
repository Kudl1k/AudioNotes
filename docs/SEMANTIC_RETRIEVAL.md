# M12.3.5 Local Semantic Retrieval — Foundation Report

## Implemented

- `EmbeddingProvider` now carries stable provider/model identity, expected
  dimensions, input-token ceiling, batching, and an explicit locality declaration.
  Its default locality is false, so an implementation must opt in before its
  vectors can enter the semantic path.
- `SemanticIndex` is a provider-neutral, in-memory dense index built from the
  existing stable M12.2 `RetrievalDocument` values. It validates finite values
  and dimensions and performs cosine ranking using normalized Float32 vectors.
- `RetrievalRankFusion` applies reciprocal rank fusion with `k = 60`, deterministic
  UUID tie-breaking, and no direct arithmetic between BM25 and cosine scores.
- `ContextRetriever` accepts an optional embedding provider. When supplied and
  local, it batches chunk/query embedding requests, fuses candidate lists, applies
  the existing source filters/diversification/context assembly, and falls back to
  BM25 if indexing or query embedding fails. No caller supplies a provider today,
  so shipped Project Chat continues using lexical retrieval.

## Runtime and model decision

No runtime/model is selected in this foundation pass. The project has no compatible
Core ML embedding model, tokenizer, vetted download metadata or model license in the
repository. Picking a multilingual Czech/English model without validating its
packaging, tokenizer, license, memory use and actual retrieval quality would be an
unsupported product decision. The protocol seam allows a native implementation to
be added after that evaluation. There is no Ollama or cloud embedding provider.

## Persistence and lifecycle limits

Vectors are disposable and in-memory only. They are not persisted, serialized,
incrementally reused by chunk fingerprint, managed under Application Support, or
included in backups. Scope caches still enforce recording/project isolation, and
the semantic index applies the same `RetrievalOptions` filters before returning
matches. A source change currently rebuilds the scope's semantic index as a whole.
No model switch/delete UX, indexing status/progress, LocalAIJobCoordinator
coordination, or background/resume flow exists. BM25 remains available if no model
is configured or any embedding operation fails.

## Validation

Unit tests cover RRF overlap/backend-only ranking, deterministic order, cosine
normalization, dimension mismatch, and rejection of providers that do not declare
local execution. No semantic-quality, Czech/English, indexing-throughput, storage,
offline-runtime, UI, or live model measurements are claimed because no concrete
embedding implementation is installed.

## Remaining work before user availability

Choose and license-review a supported multilingual local model/runtime; implement
verified explicit model download and managed storage; implement bounded incremental
vector persistence keyed by provider/model/dimensions/index version/chunk revision;
wire settings and model state; coordinate cancellable indexing; connect Project Chat
to semantic retrieval only when its index is ready; add curated quality metrics and
complete native/offline lifecycle acceptance. Keep lexical-only behavior as the
fallback throughout. M12.4 has not started.
