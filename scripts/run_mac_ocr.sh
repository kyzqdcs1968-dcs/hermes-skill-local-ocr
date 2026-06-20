#!/usr/bin/env bash
# run_mac_ocr.sh — macOS Vision OCR with Local Ollama Anonymization (100% Offline)
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_SRC="$SKILL_DIR/scripts/mac_vision_ocr.swift"
OCR_BIN="${HERMES_OCR_BIN:-$HOME/.hermes/cache/mac_vision_ocr}"
CACHE_ROOT="${HERMES_OCR_CACHE_ROOT:-$HOME/.hermes/cache/local-wechat-ocr/jobs}"
OLLAMA_BASE="${OLLAMA_HOST:-http://localhost:11434}"
OLLAMA_MODEL="${OLLAMA_MODEL:-gemma3:latest}"

usage() {
  cat <<'EOF'
Usage: run_mac_ocr.sh [options] <input-file-or-directory>

Options:
  --recursive             Recurse into subdirectories (batch mode)
  --continue-on-error     Continue processing other files after an error
  --dpi N                 Render DPI for PDFs (default: 220)
  --anonymize             Enable 100% offline smart anonymization via local Ollama
  --anonymize-model NAME  Ollama model to use (default: gemma3:latest)
  --dry-run               Validate and print the planned command only
  -h, --help              Show this help
EOF
}

die() { echo "Error: $*" >&2; exit 1; }

recursive=false
continue_on_error=false
dry_run=false
anonymize=false
dpi=220

while (($#)); do
  case "$1" in
    --recursive)         recursive=true; shift ;;
    --continue-on-error) continue_on_error=true; shift ;;
    --dpi)               shift; dpi="$1"; shift ;;
    --anonymize)         anonymize=true; shift ;;
    --anonymize-model)   shift; OLLAMA_MODEL="$1"; shift ;;
    --dry-run)           dry_run=true; shift ;;
    -h|--help)           usage; exit 0 ;;
    --)                  shift; break ;;
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

# ── Validate Ollama availability (once, before processing any files) ──────────
check_ollama() {
  # /api/tags is a GET endpoint that lists available models — reliable health probe
  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$OLLAMA_BASE/api/tags") || true
  [[ "$http_code" == "200" ]] || die "Ollama is not reachable at $OLLAMA_BASE (HTTP $http_code). Start Ollama first: open -a Ollama"

  # Verify the requested model is pulled
  local models
  models=$(curl -s -m 5 "$OLLAMA_BASE/api/tags" | python3 -c '
import sys, json
data = json.load(sys.stdin)
print("\n".join(m["name"] for m in data.get("models", [])))
')
  if ! echo "$models" | grep -qF "$OLLAMA_MODEL"; then
    echo "Warning: model '$OLLAMA_MODEL' not found locally. Available models:" >&2
    echo "$models" >&2
    echo "Pull it first: ollama pull $OLLAMA_MODEL" >&2
    die "Model '$OLLAMA_MODEL' not available"
  fi
}

[[ "$anonymize" == true && "$dry_run" == false ]] && check_ollama

# ── Create job directory ──────────────────────────────────────────────────────
timestamp="$(date '+%Y%m%d-%H%M%S')"
job_root="$CACHE_ROOT/$timestamp-$$"
staged_input="$job_root/input/$(basename "$input")"

if [[ "$dry_run" == true ]]; then
  printf 'Mode:           %s\n' "$input_mode"
  printf 'Input:          %s\n' "$input"
  printf 'Anonymize:      %s\n' "$anonymize"
  printf 'Ollama model:   %s\n' "$OLLAMA_MODEL"
  printf 'OCR binary:     %s\n' "$OCR_BIN"
  printf 'Job root:       %s\n' "$job_root"
  exit 0
fi

mkdir -p "$job_root/output" "$job_root/input"
cp -R "$input" "$staged_input"

# ── Local Ollama Anonymization ────────────────────────────────────────────────
local_anonymize_file() {
  local md_file="$1"
  echo "  [anonymize] $OLLAMA_MODEL ← $(basename "$md_file")" >&2

  local raw_text
  raw_text=$(cat "$md_file")

  # Build JSON payload via Python to handle all escaping correctly
  local json_payload
  json_payload=$(python3 - "$raw_text" <<'PYEOF'
import sys, json

system_prompt = """你是一位专业的法律合规与数据安全专家。任务是将输入的法律诉讼文本进行严格的智能脱敏处理，同时保留案件的全部商业逻辑和法律事实。

请将文本中的以下敏感实体进行标准化占位替换：
1. 自然人姓名（原告、被告、证人、代理律师等）→ [张某甲]、[李某乙]、[代理律师A] 等；
2. 律所名称 → [某律师事务所]；
3. 具体公司/企业名称 → [某技术公司]、[某商贸公司] 等；
4. 18位身份证号 → [身份证号X]；
5. 手机号、固话 → [电话X]；
6. 银行卡号、账号 → [账号X]；
7. 具体门牌住址 → [住址X]；
8. 邮箱地址 → [邮箱X]。

注意：
- 保持案件事实陈述、证据描述、涉案金额、法律条文、日期和原 Markdown 排版结构 100% 完整；
- 同一人物在全文中使用同一占位符，保持逻辑一致性；
- 不添加任何解释、注释或额外内容，直接输出脱敏后的 Markdown 全文。"""

user_text = sys.argv[1]
payload = {
    "model": sys.argv[2] if len(sys.argv) > 2 else "gemma3:latest",
    "messages": [
        {"role": "system", "content": system_prompt},
        {"role": "user",   "content": user_text}
    ],
    "stream": False
}
print(json.dumps(payload, ensure_ascii=False))
PYEOF
  )

  # Inject actual model name (Python receives it as argv[2])
  json_payload=$(python3 - "$raw_text" "$OLLAMA_MODEL" <<'PYEOF'
import sys, json

system_prompt = """你是一位专业的法律合规与数据安全专家。任务是将输入的法律诉讼文本进行严格的智能脱敏处理，同时保留案件的全部商业逻辑和法律事实。

请将文本中的以下敏感实体进行标准化占位替换：
1. 自然人姓名（原告、被告、证人、代理律师等）→ [张某甲]、[李某乙]、[代理律师A] 等；
2. 律所名称 → [某律师事务所]；
3. 具体公司/企业名称 → [某技术公司]、[某商贸公司] 等；
4. 18位身份证号 → [身份证号X]；
5. 手机号、固话 → [电话X]；
6. 银行卡号、账号 → [账号X]；
7. 具体门牌住址 → [住址X]；
8. 邮箱地址 → [邮箱X]。

注意：
- 保持案件事实陈述、证据描述、涉案金额、法律条文、日期和原 Markdown 排版结构 100% 完整；
- 同一人物在全文中使用同一占位符，保持逻辑一致性；
- 不添加任何解释、注释或额外内容，直接输出脱敏后的 Markdown 全文。"""

user_text = sys.argv[1]
model    = sys.argv[2]
payload = {
    "model": model,
    "messages": [
        {"role": "system", "content": system_prompt},
        {"role": "user",   "content": user_text}
    ],
    "stream": False
}
print(json.dumps(payload, ensure_ascii=False))
PYEOF
  )

  local response
  # -m 600: allow up to 10 min for large documents
  response=$(curl -s -m 600 -X POST \
    -H "Content-Type: application/json" \
    -d "$json_payload" \
    "$OLLAMA_BASE/api/chat") || die "Ollama request failed for $(basename "$md_file")"

  local clean_text
  clean_text=$(echo "$response" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    print(data["message"]["content"], end="")
except Exception as e:
    sys.exit(f"Parse error: {e}")
') || die "Failed to parse Ollama response for $(basename "$md_file")"

  if [[ -n "$clean_text" ]]; then
    printf '%s' "$clean_text" > "$md_file"
    echo "  [anonymize] done → $(basename "$md_file")" >&2
  else
    echo "  [anonymize] Warning: empty response, skipping overwrite of $(basename "$md_file")" >&2
  fi
}

# ── Run OCR (+ optional anonymization per file) ───────────────────────────────
run_ocr_on_file() {
  local f="$1"
  "$OCR_BIN" "$f" --output-dir "$job_root/output" --dpi "$dpi"

  if [[ "$anonymize" == true ]]; then
    local stem
    stem="$(basename "${f%.*}")"
    local md_out="$job_root/output/${stem}.md"
    if [[ -f "$md_out" ]]; then
      local_anonymize_file "$md_out"
    else
      echo "  [anonymize] Warning: expected $md_out not found, skipping" >&2
    fi
  fi
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
md_count="$(find "$job_root/output" -type f -name '*.md'        -size +0c 2>/dev/null | wc -l | tr -d ' ')"
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
  "pdf_files": $pdf_count,
  "anonymize_applied": $anonymize,
  "ollama_model": "$OLLAMA_MODEL"
}
JSON

printf 'Job directory:   %s\n' "$job_root"
printf 'Markdown files:  %s\n' "$md_count"
printf 'PDF/A files:     %s\n' "$pdf_count"
printf 'Anonymization:   %s\n' "$anonymize"
[[ "$anonymize" == true ]] && printf 'Ollama model:    %s\n' "$OLLAMA_MODEL"
[[ "$fail_count" -gt 0 ]] && {
  printf 'Failed files:    %s\n' "$fail_count"
  for f in "${fail_files[@]}"; do printf '  - %s\n' "$f"; done
}
cat "$result_json"
