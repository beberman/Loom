describe apply-transaction still shows one caller. 

Calls made from inside (test ...) macro bodies aren't attributed because defmacro is not expanded

TODO: watch already expands ~ to find the file so ~/lisp works.
However unwatch does not because it pulls the full directory name in
as the name of the workspace

I have an unexplained number. Indexing Loom went from 571 entities
before the resolution passes to 581 after. Resolution creates edges,
not entities, so that shouldn't move at all. Every suite passes
including reindexing-produces-an-identical-index, so it isn't drift
between incremental and rebuilt indexes — but I haven't accounted for
it, and I'd rather say so than let it pass as noise. Worth me chasing
before this is called done. 