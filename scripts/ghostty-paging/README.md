# Paging renderer

The paging renderer is Ghostty at `deps/ghostty/UPSTREAM_COMMIT` plus the
patch series in `deps/ghostty/patches/`, built by `scripts/deps`; see
[deps/README.md](../../deps/README.md). Its probes and fixtures live in
`deps/ghostty/tests/`.

`compiler-context.py` reads the renderer's compiler definition from the
package manifest so CI and `scripts/swiftpm` can pass it to every target.
[RESULTS.md](RESULTS.md) records the original feasibility experiment; its
historical commands refer to files that have since moved.
