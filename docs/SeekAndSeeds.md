Is this a lexical ceiling? Mostly no — and the sheet you asked for proves it

The literature's ceiling argument is real, but it applies to vocabulary-mismatch queries — "the bit that merges edits" — where the asker's words and the author's words don't overlap. Our 450 known-item cases are built from the entities' own names and docstrings, so they are lexically answerable by construction. An 86.7% score on a lexically-answerable set is not evidence of the lexical ceiling; it's evidence of mechanical defects. And we can now name them:

- BUG-0041: 35 of 450 cases return eight seeds carrying ≤3 distinct names; 8 return one name eight times. The retriever found the answer's neighborhood and spent the whole budget saying so.
- The stopword list is eating identifier words. I just checked: add, get, set, new, make, use, update, change, fix are all in *context-stopwords*. That list was written for English chatter ("how does the drawing tool work"), but in a code tree those are the commonest identifier words. Look at the name-family misses in your spreadsheet: Game.addDefinition, wrappedLogger.setLevel, getDefinitionList, getDotObj, getTypeFromObj, getInterface — every one loses a load-bearing word before matching even starts. "wrapped logger set level" competes on three words, not four, and set is the one that separates setLevel from the eight bare loggers.

Those two defects plausibly account for most of the name family's 25 misses. Dense retrieval fixes neither — an embedding search that proposes wrappedLogger.setLevel still dies in the same eight-slots-of-logger admission, and still gets its query mangled by the same tokenizer.

Reviewing my own hybrid recommendation in this light

The hybrid stemmer did what I claimed — recovered 42/45, kept BUG-0040 closed — but notice what it was: defensive. It recovered losses; it added nothing. And that's the pattern of the whole month: four ranking mechanisms (coverage-by-word, provenance rank, name analyzer, idf), all at baseline or worse. The honest lesson is that reordering eight slots cannot add information. The only levers that changed outcomes were candidate generation (what reaches the pool) and slot allocation (BUG-0041). Dense retrieval is candidate generation — so your proposal is on the correct side of the line our own data drew. That's the strongest argument for it, stronger than the literature.

So yes to dense — the project already decided this, in fact

seed-entities' own docstring: "The naive half of SS11's 'first implementation is simple', and the half most obviously worth replacing... Semantic seeding is what Qdrant is for in the target architecture." This isn't scope creep; it's the planned step, arriving on evidence. Two documents need reconciling: REQ-0039's "WHAT THIS IS NOT: Not embeddings" clause would be superseded (its objection — an answer nobody can explain — is met by labeling seeds with provenance, which DES-0032's term report already does for lexical matches), and that reversal wants a DEC.

Three design constraints from what we've measured:

1. Fuse, don't replace. Lexical stays authoritative for name queries (find untouched per REQ-0045 R4). Dense proposes candidates into the same pool; RRF is the standard parameter-light fusion and avoids calibrating cosines against banded scores.
2. Skip Qdrant for now. Front-end is 3,457 definitions, game-server 1,811. At that scale a flat vector array with brute-force cosine is ~10MB and sub-millisecond — no vector DB, no service, and DEC-0001-compliant (a derived, rebuildable sidecar, like the index itself).
3. Protect the absence report. Cosine similarity always returns nearest neighbors — dense retrieval makes "nothing here does that" harder, not easier. A semantic seed must never mark a term ANSWERED, or the r37 cases break exactly the way DES-0034 broke them.

On DeepSeek specifically: wrong tool, right instinct

DeepSeek's API is a generation model family — it doesn't offer a dedicated embedding model, and using a chat LLM to produce embeddings is the wrong mechanism. For code retrieval you want a purpose-built embedder:

- Local (fits this WSL setup, your code never leaves the machine, no per-query cost): nomic-embed-text or bge-m3 via Ollama; there are code-tuned options too.
- API, best-in-class for code: Voyage's code-tuned embeddings.

Where DeepSeek would slot in well: generating the instrument. Before adding dense we need a case family it can actually score on — vocabulary-mismatch/paraphrase queries ("the bit that merges edits" for compose-view), which our current families deliberately can't measure. That's REQ-0046's lesson applied forward: write the bar first, or you can't show the mechanism did anything. A cheap generator producing paraphrases of 150 docstrings is exactly a DeepSeek-shaped job.

Recommended sequence

1. Fix BUG-0041 (bounded: cap same-name admissions at ~3, which R8 needs, not 8).
2. Fix the stopword list — split it: words dropped from queries about code ≠ words meaningless in code. get/set/add/new/make/update must survive when the query is name-shaped. Remeasure; I'd expect several points on the name family from these two alone, which sharpens the real lexical baseline before dense is judged against it.
3. Build the paraphrase family (LLM-generated; this is the DeepSeek job if you want it).
4. Then dense: local embedder, flat-array cosine, RRF fusion, provenance-labeled seeds, measured against the paraphrase family with acceptance and known-item as the do-no-harm guards.
5. Record it: DEC superseding REQ-0039's embeddings clause; architect the fusion via the workflow.

If steps 1–2 push known-item to ~92% and the paraphrase family still sits low, that residue is the true semantic gap, and dense earns its dependency on a measurement nobody can argue with.