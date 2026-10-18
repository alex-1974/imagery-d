#!/usr/bin/env bash
# R-IM-03e: exact-revision, same-compiler, no-benchmark D vs D codegen evidence.
# Read-only checkout/repositories. Writes exclusively to isolated output path.
# Invoke from imagery-d Git working tree:
#   bash tools/research/compare_r_im_03e_codegen.sh ldc2 /tmp/rim03e-codegen
set -euo pipefail

BASE="68ddbdefc5b9cfefd95fe8545ba4848fc5736beb"
CAND="ae36974af9369d7bbdbbecf9b8619d2da52e59be"
RASTER="2f2415851e45001df92ce56dad409f680684ba8d"
COMPILER="${1:-ldc2}"
OUT="${2:-$(mktemp -d "${TMPDIR:-/tmp}/r-im-03e-codegen-XXXXXX")}"

REPO="$(git rev-parse --show-toplevel)"
cd "$REPO"
for cmd in git tar realpath readlink sha256sum size nm objdump awk stat; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: missing required tool $cmd" >&2; exit 2;
    }
done
command -v "$COMPILER" >/dev/null 2>&1 || {
    echo "ERROR: compiler not in PATH: $COMPILER" >&2; exit 2;
}
command -v dub >/dev/null 2>&1 || {
    echo "ERROR: dub not in PATH" >&2; exit 2;
}
for rev in "$BASE" "$CAND"; do
    git cat-file -e "${rev}^{commit}" || {
        echo "ERROR: exact revision $rev unavailable (fetch full history)" >&2
        exit 3
    }
done

DEPENDENCY="$REPO/deps/raster-d"
if [[ ! -d "$DEPENDENCY/.git" && ! -f "$DEPENDENCY/.git" ]]; then
    echo "ERROR: pinned raster-d checkout required under deps/raster-d" >&2
    exit 3
fi
ACTUAL="$(git -C "$DEPENDENCY" rev-parse HEAD)"
if [[ "$ACTUAL" != "$RASTER" ]]; then
    echo "ERROR: raster-d HEAD $ACTUAL != pinned $RASTER" >&2
    exit 3
fi

mkdir -p "$OUT"
OUT="$(realpath "$OUT")"
PAIR="$OUT/pair"
if [[ -e "$PAIR" ]]; then
    echo "ERROR: destination $PAIR already exists; use a fresh output directory" >&2
    exit 3
fi
mkdir -p "$PAIR"/{baseline,candidate} "$OUT/evidence"
ln -s "$DEPENDENCY" "$PAIR/raster-d"

{
    echo "RIM03E_SCHEMA=1"
    echo "RIM03E_PURPOSE=D-vs-D release codegen only, no speedup claim"
    echo "RIM03E_BASE_SHA=$BASE"
    echo "RIM03E_CAND_SHA=$CAND"
    echo "RIM03E_RASTER_SHA=$RASTER"
    echo "RIM03E_PARENT_WORKTREE_HEAD=$(git rev-parse HEAD)"
    echo "RIM03E_DATE_UTC=$(date -u +%FT%TZ)"
    echo "RIM03E_MACHINE=$(uname -srvmo)"
    echo "RIM03E_COMPILER=$COMPILER"
    "$COMPILER" --version
    dub --version
    echo "RIM03E_BUILD=both variants same toolchain, dub release, no boundscheck weakening"
} | tee "$OUT/evidence/provenance.log"

SOURCE="experiments/r_im_03a_levels/source/imagery/presentation/levels_integer_research.d"
for variant in baseline candidate; do
    if [[ "$variant" == baseline ]]; then sha="$BASE"; else sha="$CAND"; fi
    dest="$PAIR/$variant"
    git archive --format=tar "$sha" | tar -xf - -C "$dest"
    # Verify captured source file was built from exactly the named revision.
    repo_hash="$(git show "$sha:$SOURCE" | sha256sum | awk '{print $1}')"
    archive_hash="$(sha256sum "$dest/$SOURCE" | awk '{print $1}')"
    [[ "$repo_hash" == "$archive_hash" ]] || {
        echo "ERROR: source hash mismatch in $variant" >&2; exit 4;
    }
    echo "RIM03E_SOURCE_HASH,$variant,$archive_hash" | tee -a "$OUT/evidence/provenance.log"

    root="$dest/experiments/r_im_03a_levels/bench_03c"
    echo "RIM03E_BUILD_BEGIN,$variant" | tee -a "$OUT/evidence/provenance.log"
    # Preserve full verbose invocation/flags and build provenance; no workload run.
    (
        cd "$dest"
        dub build --root="$root" --compiler="$COMPILER" --build=release --force --verbose
    ) > "$OUT/evidence/$variant-build.log" 2>&1 || {
        cat "$OUT/evidence/$variant-build.log" >&2
        echo "ERROR: DUB build failed for $variant" >&2; exit 5;
    }
    bin="$root/r-im-03c-levels-math-benchmark"
    [[ -x "$bin" ]] || {
        echo "ERROR: built executable not found at $bin" >&2; exit 5;
    }
    sha256sum "$bin" > "$OUT/evidence/$variant-executable.sha256"
    size -A "$bin" > "$OUT/evidence/$variant-sections.txt"
    size "$bin" > "$OUT/evidence/$variant-size.txt"
    nm --defined-only --print-size --size-sort --demangle=dlang "$bin" > "$OUT/evidence/$variant-nm.txt"
    objdump -d --demangle=dlang --no-show-raw-insn "$bin" > "$OUT/evidence/$variant-asm.txt"

    bytes="$(stat -c %s "$bin")"
    text_bytes="$(awk '$1==".text"{print $2; exit}' "$OUT/evidence/$variant-sections.txt")"
    [[ "$text_bytes" =~ ^[0-9]+$ ]] || { echo "ERROR: no .text for $variant" >&2; exit 6; }
    # D demangling is a best effort: LLVM may have inlined/erased functions.
    symbols="$(grep -Eic 'tryLevelsInteger|levels_integer_research.*execute' "$OUT/evidence/$variant-nm.txt" || true)"
    {
        echo "RIM03E_EXECUTABLE_BYTES,$variant,$bytes"
        echo "RIM03E_TEXT_BYTES,$variant,$text_bytes"
        echo "RIM03E_MATCHING_DEFINED_SYMBOLS,$variant,$symbols"
        echo "RIM03E_SYMBOL_SAMPLES_BEGIN,$variant"
        grep -Ei 'tryLevelsInteger|levels_integer_research.*execute' \
            "$OUT/evidence/$variant-nm.txt" | tail -n 24 || true
        echo "RIM03E_SYMBOL_SAMPLES_END,$variant"
        echo "RIM03E_BUILD_DONE,$variant"
    } | tee -a "$OUT/evidence/provenance.log"
done

# Text/disassembly are artifacts for human review; do not infer speed from size.
base_exe="$(awk -F, '$1=="RIM03E_EXECUTABLE_BYTES" && $2=="baseline" {print $3}' "$OUT/evidence/provenance.log")"
cand_exe="$(awk -F, '$1=="RIM03E_EXECUTABLE_BYTES" && $2=="candidate" {print $3}' "$OUT/evidence/provenance.log")"
base_text="$(awk -F, '$1=="RIM03E_TEXT_BYTES" && $2=="baseline" {print $3}' "$OUT/evidence/provenance.log")"
cand_text="$(awk -F, '$1=="RIM03E_TEXT_BYTES" && $2=="candidate" {print $3}' "$OUT/evidence/provenance.log")"
echo "RIM03E_EXECUTABLE_DELTA_BYTES=$((cand_exe-base_exe))" | tee -a "$OUT/evidence/provenance.log"
echo "RIM03E_TEXT_DELTA_BYTES=$((cand_text-base_text))" | tee -a "$OUT/evidence/provenance.log"
echo "RIM03E_TIMING_VERDICT=none (no timed image operation executed)" | tee -a "$OUT/evidence/provenance.log"
echo "RIM03E_OUTPUT=$OUT/evidence"
