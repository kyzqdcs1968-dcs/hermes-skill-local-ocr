#!/usr/bin/env bash
# run_mac_ocr.sh — macOS Vision OCR (no Windows VM, no WeChat required)
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_SRC="$SKILL_DIR/scripts/mac_vision_ocr.swift"
OCR_BIN="${HERMES_OCR_BIN:-$HOME/.hermes/cache/mac_vision_ocr}"
CACHE_ROOT="${HERMES_OCR_CACHE_ROOT:-$HOME/.hermes/cache/local-wechat-ocr/jobs}"

usage() {
  cat <<'EOF'
Usage: run_mac_ocr.sh [options] <input-file-or-directory>

Options:
  --recursive             Recurse into subdirectories (batch mode)
  --continue-on-error     Continue processing other files after an error
  --dpi N                 Render DPI for PDFs (default: 220)
  --dry-run               Validate and print the planned command only
  -h, --help              Show this help
EOF
}

die() { echo "Error: $*" >&2; exit 1; }

recursive=false
continue_on_error=false
dry_run=false
dpi=220

while (($#)); do
  case "$1" in
    --recursive)        recursive=true; shift ;;
    --continue-on-error) continue_on_error=true; shift ;;
    --dpi)              shift; dpi="$1"; shift ;;
    --dry-run)          dry_run=true; shift ;;
    -h|--help)          usage; exit 0 ;;
    --)                 shift; break ;;
    -*) die "Unknown option: $1" ;;
    *)  break ;;
  esac
done

(($# == 1)) || die "Provide exactly one input file or directory"
input="$1"
[[ -e "$input" ]] || die "Input path does not exist: $input"

supported_ext() {
  case "${1##*.}" in
    pdf|PDF|png|PNG|jpg|JPG|jpeg|JPEG|bmp|BMP|tiff|TIFF|tif|TIF|webp|WEBP|gif|GIF) return 0 ;;
    *) return 1 ;;
  esac
}

if [[ -f "$input" ]]; then
  supported_ext "$input" || die "Unsupported file type: $input"
  input_mode="Single"
elif [[ -d "$input" ]]; then
  input_mode="Batch"
else
  die "Input must be a file or directory: $input"
fi

# ── Compile OCR binary once (cached) ─────────────────────────────────────────
compile_ocr_bin() {
  local sdk
  sdk="$(xcrun --show-sdk-path 2>/dev/null)" || sdk=""
  local sdk_flag=()
  [[ -n "$sdk" ]] && sdk_flag=(-sdk "$sdk")
  echo "Compiling OCR engine (first-run only)…" >&2
  mkdir -p "$(dirname "$OCR_BIN")"
  local compile_log
  compile_log="$(mktemp)"
  if ! swiftc "$SWIFT_SRC" -o "$OCR_BIN" \
    "${sdk_flag[@]}" \
    -framework Foundation \
    -framework AppKit \
    -framework Vision \
    -framework PDFKit \
    -framework CoreGraphics \
    -framework CoreText \
    -framework ImageIO \
    -O 2>"$compile_log"; then
    cat "$compile_log" >&2
    rm -f "$compile_log"
    die "Swift compilation failed"
  fi
  rm -f "$compile_log"
  echo "OCR engine ready." >&2
}

[[ "$dry_run" == false ]] && {
  command -v swiftc >/dev/null 2>&1 || die "swiftc not found — install Xcode Command Line Tools: xcode-select --install"
  if [[ ! -f "$OCR_BIN" || "$SWIFT_SRC" -nt "$OCR_BIN" ]]; then
    compile_ocr_bin
  fi
}

# ── Create job directory ──────────────────────────────────────────────────────
timestamp="$(date '+%Y%m%d-%H%M%S')"
job_root="$CACHE_ROOT/$timestamp-$$"
staged_input="$job_root/input/$(basename "$input")"

if [[ "$dry_run" == true ]]; then
  printf 'Mode:       %s\n' "$input_mode"
  printf 'Input:      %s\n' "$input"
  printf 'OCR binary: %s\n' "$OCR_BIN"
  printf 'Job root:   %s\n' "$job_root"
  exit 0
fi

mkdir -p "$job_root/output" "$job_root/input"
cp -R "$input" "$staged_input"

# ── Run OCR ──────────────────────────────────────────────────────────────────
run_ocr_on_file() {
  local f="$1"
  "$OCR_BIN" "$f" --output-dir "$job_root/output" --dpi "$dpi"
}

success_count=0
fail_count=0
fail_files=()

if [[ "$input_mode" == "Single" ]]; then
  run_ocr_on_file "$staged_input"
  success_count=1
else
  find_args=("$staged_input")
  [[ "$recursive" == false ]] && find_args+=(-maxdepth 1)
  find_args+=(-type f)
  while IFS= read -r f; do
    supported_ext "$f" || continue
    if run_ocr_on_file "$f"; then
      ((success_count++))
    else
      ((fail_count++))
      fail_files+=("$f")
      [[ "$continue_on_error" == false ]] && die "OCR failed for: $f (use --continue-on-error to skip)"
    fi
  done < <(find "${find_args[@]}" 2>/dev/null)
fi

# ── Verify output ─────────────────────────────────────────────────────────────
md_count="$(find "$job_root/output" -type f -name '*.md'     -size +0c 2>/dev/null | wc -l | tr -d ' ')"
pdf_count="$(find "$job_root/output" -type f -name '*.pdfa.pdf' -size +0c 2>/dev/null | wc -l | tr -d ' ')"

[[ "$md_count"  -gt 0 ]] || die "No Markdown output produced; check $job_root"
[[ "$pdf_count" -gt 0 ]] || die "No PDF/A output produced; check $job_root"

# ── Write result.json ─────────────────────────────────────────────────────────
result_json="$job_root/result.json"
cat > "$result_json" << JSON
{
  "success": true,
  "job_dir": "$job_root",
  "processed": $success_count,
  "failed": $fail_count,
  "markdown_files": $md_count,
  "pdf_files": $pdf_count
}
JSON

printf 'Job directory:   %s\n' "$job_root"
printf 'Markdown files:  %s\n' "$md_count"
printf 'PDF/A files:     %s\n' "$pdf_count"
[[ "$fail_count" -gt 0 ]] && {
  printf 'Failed files:    %s\n' "$fail_count"
  for f in "${fail_files[@]}"; do printf '  - %s\n' "$f"; done
}
cat "$result_json"
