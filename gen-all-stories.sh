#!/usr/bin/env bash
set -euo pipefail

# generate-stories.sh
# Generates Storybook stories by parsing TypeScript component source files.
# No AI API required — reads props directly from component source.
#
# Usage:
#   ./generate-stories.sh [options] [ComponentName...]
#
# Options:
#   -s, --src DIR      Source components directory (default: ./src/components)
#   -o, --out DIR      Output directory for stories (default: ./src/stories)
#   -e, --ext EXT      Extension: tsx or jsx (default: tsx)
#   -f, --force        Overwrite existing story files
#   -d, --dry-run      Print what would be generated without writing files
#   -v, --verbose      Show parsed props for each component
#   -h, --help         Show this help
#
# Examples:
#   ./generate-stories.sh
#   ./generate-stories.sh Button Badge Alert
#   ./generate-stories.sh --src src/components --out src/stories --force

# ── Defaults ─────────────────────────────────────────────────────────────────
SRC_DIR="./src/components"
OUT_DIR="./src/stories"
EXT="tsx"
FORCE=0
DRY_RUN=0
VERBOSE=0

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; DIM='\033[2m'; BOLD='\033[1m'; RESET='\033[0m'

err()     { echo -e "${RED}error:${RESET} $*" >&2; }
info()    { echo -e "${CYAN}→${RESET} $*"; }
ok()      { echo -e "${GREEN}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}!${RESET} $*"; }
verbose() { [[ $VERBOSE -eq 1 ]] && echo -e "${DIM}  $*${RESET}" || true; }

usage() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//'
  exit 0
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
TARGETS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    -s|--src)      SRC_DIR="$2"; shift 2 ;;
    -o|--out)      OUT_DIR="$2"; shift 2 ;;
    -e|--ext)      EXT="$2";     shift 2 ;;
    -f|--force)    FORCE=1;      shift   ;;
    -d|--dry-run)  DRY_RUN=1;   shift   ;;
    -v|--verbose)  VERBOSE=1;   shift   ;;
    -h|--help)     usage ;;
    -*)            err "Unknown option: $1"; exit 1 ;;
    *)             TARGETS+=("$1"); shift ;;
  esac
done

[[ "$EXT" != "tsx" && "$EXT" != "jsx" ]] && { err "--ext must be tsx or jsx"; exit 1; }
[[ -d "$SRC_DIR" ]] || { err "Source directory not found: $SRC_DIR"; exit 1; }

mkdir -p "$OUT_DIR"

# ── Prop type → Storybook control + example value ─────────────────────────────
# Returns "control_type|example_value"
map_type() {
  local t="$1"
  local name="$2"
  local tl
  tl=$(echo "$t" | tr '[:upper:]' '[:lower:]' | tr -d ' ')

  if [[ "$tl" == "boolean" ]]; then
    echo "boolean|false"; return
  fi

  if [[ "$tl" == "string" ]]; then
    case "$name" in
      *label*|*title*|*heading*)              echo "text|'Example label'" ;;
      *href*|*url*|*link*)                    echo "text|'https://example.com'" ;;
      *placeholder*)                          echo "text|'Enter value…'" ;;
      *id*)                                   echo "text|'element-id'" ;;
      *class*|*className*)                    echo "text|'custom-class'" ;;
      *name*)                                 echo "text|'field-name'" ;;
      *value*)                                echo "text|'value'" ;;
      *text*|*content*|*description*|*message*) echo "text|'Example text'" ;;
      *src*|*image*)                          echo "text|'https://picsum.photos/200'" ;;
      *alt*)                                  echo "text|'Descriptive alt text'" ;;
      *color*|*colour*)                       echo "color|'#0070f3'" ;;
      *date*)                                 echo "text|'2024-01-01'" ;;
      *icon*)                                 echo "text|'star'" ;;
      *)                                      echo "text|'Example'" ;;
    esac
    return
  fi

  if [[ "$tl" == "number" ]]; then
    case "$name" in
      *min*)    echo "number|0" ;;
      *max*)    echo "number|100" ;;
      *step*)   echo "number|1" ;;
      *count*|*total*|*length*) echo "number|5" ;;
      *width*)  echo "number|300" ;;
      *height*) echo "number|200" ;;
      *size*)   echo "number|24" ;;
      *)        echo "number|10" ;;
    esac
    return
  fi

  if [[ "$tl" == "reactnode" || "$name" == "children" ]]; then
    echo "text|'Content goes here'"; return
  fi

  if [[ "$tl" == *"=>"* || "$tl" == "function" || "$name" == on* ]]; then
    echo "action|undefined"; return
  fi

  # Union of string literals
  if [[ "$t" == *"|"* ]]; then
    local opts
    opts=$(echo "$t" | tr '|' '\n' | sed "s/['\"]//g" | tr -d ' ' | head -8 | tr '\n' ',' | sed 's/,$//')
    local first
    first=$(echo "$t" | tr '|' '\n' | sed "s/['\"]//g" | tr -d ' ' | head -1)
    echo "select:${opts}|'${first}'"
    return
  fi

  if [[ "$tl" == *"[]"* || "$tl" == "array" ]]; then
    echo "object|[]"; return
  fi

  echo "object|{}"
}

# ── Parse props from a component's .tsx source ───────────────────────────────
# Outputs lines of: propname|type|required|defaultval
parse_props() {
  local file="$1"
  local name="$2"
  local props_block=""

  # Try: interface ComponentNameProps { ... }
  props_block=$(awk "
    /interface[[:space:]]+${name}Props[[:space:]]*(\{|extends)/ { found=1; depth=0 }
    found {
      for(i=1;i<=length(\$0);i++) {
        c=substr(\$0,i,1)
        if(c==\"{\") depth++
        if(c==\"}\") { depth--; if(depth==0){ print; found=0; next } }
      }
      print
    }
  " "$file" 2>/dev/null || true)

  # Fallback: interface Props { ... }
  if [[ -z "$props_block" ]]; then
    props_block=$(awk '
      /interface[[:space:]]+Props[[:space:]]*(\{|extends)/ { found=1; depth=0 }
      found {
        for(i=1;i<=length($0);i++) {
          c=substr($0,i,1)
          if(c=="{") depth++
          if(c=="}") { depth--; if(depth==0){ print; found=0; next } }
        }
        print
      }
    ' "$file" 2>/dev/null || true)
  fi

  # Fallback: type ComponentNameProps = { ... }  or  type Props = { ... }
  if [[ -z "$props_block" ]]; then
    props_block=$(awk "
      /type[[:space:]]+(${name}Props|Props)[[:space:]]*=[[:space:]]*\{/ { found=1; depth=0 }
      found {
        for(i=1;i<=length(\$0);i++) {
          c=substr(\$0,i,1)
          if(c==\"{\") depth++
          if(c==\"}\") { depth--; if(depth==0){ print; found=0; next } }
        }
        print
      }
    " "$file" 2>/dev/null || true)
  fi

  [[ -z "$props_block" ]] && return

  echo "$props_block" | while IFS= read -r line; do
    # Skip comments, braces, blank lines
    [[ "$line" =~ ^[[:space:]]*(//|/\*|\*|$|\{|\}) ]] && continue

    # Match: propName?: type;  or  propName: type;
    if [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)(\?)?:[[:space:]]*(.*) ]]; then
      local pname="${BASH_REMATCH[1]}"
      local optional="${BASH_REMATCH[2]}"
      local ptype="${BASH_REMATCH[3]}"

      [[ "$pname" == "ref" || "$pname" == "key" || "$pname" == "style" ]] && continue

      # Clean trailing semicolon and inline comments
      ptype=$(echo "$ptype" | sed 's/;[[:space:]]*$//' | sed 's/\/\/.*$//' | sed 's/[[:space:]]*$//')

      local required="true"
      [[ "$optional" == "?" ]] && required="false"

      # Look for default value in destructured function params
      local default=""
      default=$(sed -n "s/.*${pname} = \([^,){}]*\).*/\1/p" "$file" 2>/dev/null | head -1 | sed 's/[[:space:]]*$//' || true)

      echo "${pname}|${ptype}|${required}|${default}"
    fi
  done
}

# ── Build argTypes block ───────────────────────────────────────────────────────
build_arg_types() {
  local -a prop_lines=("$@")
  [[ ${#prop_lines[@]} -eq 0 ]] && return
  echo "  argTypes: {"
  for line in "${prop_lines[@]}"; do
    IFS='|' read -r pname ptype required default <<< "$line"
    local mapped control desc
    mapped=$(map_type "$ptype" "$pname")
    control="${mapped%%|*}"
    desc="$ptype"
    [[ "$required" == "true" ]] && desc="${desc} (required)"

    if [[ "$control" == select:* ]]; then
      local opts="${control#select:}"
      # Format as JS array
      local arr
      arr=$(echo "$opts" | sed "s/\([^,]*\)/'\1'/g")
      echo "    ${pname}: { control: 'select', options: [${arr}], description: '${desc}' },"
    elif [[ "$control" == "action" ]]; then
      echo "    ${pname}: { action: '${pname}', description: '${desc}' },"
    else
      echo "    ${pname}: { control: '${control}', description: '${desc}' },"
    fi
  done
  echo "  },"
}

# ── Build default args block ───────────────────────────────────────────────────
build_default_args() {
  local -a prop_lines=("$@")
  [[ ${#prop_lines[@]} -eq 0 ]] && return
  local has_args=0
  local lines=()
  for line in "${prop_lines[@]}"; do
    IFS='|' read -r pname ptype required default <<< "$line"
    # Skip callbacks
    [[ "$pname" == on* || "$ptype" == *"=>"* ]] && continue
    local val="$default"
    if [[ -z "$val" ]]; then
      local mapped
      mapped=$(map_type "$ptype" "$pname")
      val="${mapped##*|}"
    fi
    lines+=("    ${pname}: ${val},")
    has_args=1
  done
  if [[ $has_args -eq 1 ]]; then
    echo "  args: {"
    for l in "${lines[@]}"; do echo "$l"; done
    echo "  },"
  fi
}

# ── Build variant stories from union / boolean props ──────────────────────────
build_variant_stories() {
  local -a prop_lines=("$@")
  local out=""

  # One story per option of the first union prop (up to 4 options)
  for line in "${prop_lines[@]}"; do
    IFS='|' read -r pname ptype required default <<< "$line"
    if [[ "$ptype" == *"|"* ]]; then
      local i=0
      while IFS= read -r raw_opt; do
        local opt
        opt=$(echo "$raw_opt" | tr -d " '\"")
        [[ -z "$opt" ]] && continue
        local story_name
        story_name=$(echo "${pname}${opt}" | awk '{print toupper(substr($0,1,1)) substr($0,2)}' | sed 's/[^a-zA-Z0-9]//g')
        out+="\nexport const ${story_name}: Story = {\n  args: { ${pname}: '${opt}' },\n};\n"
        ((i++)) || true
        [[ $i -ge 4 ]] && break
      done < <(echo "$ptype" | tr '|' '\n')
      break
    fi
  done

  # If no union found, create stories for up to 2 boolean props
  if [[ -z "$out" ]]; then
    local bool_count=0
    for line in "${prop_lines[@]}"; do
      IFS='|' read -r pname ptype required default <<< "$line"
      if [[ "$ptype" == "boolean" ]]; then
        local story_name
        story_name=$(echo "$pname" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
        out+="\nexport const ${story_name}: Story = {\n  args: { ${pname}: true },\n};\n"
        ((bool_count++)) || true
        [[ $bool_count -ge 2 ]] && break
      fi
    done
  fi

  echo -e "$out"
}

# ── Generate a single story file ──────────────────────────────────────────────
generate_story() {
  local name="$1"
  local src_file="$SRC_DIR/${name}.tsx"
  local out_file="$OUT_DIR/${name}.stories.${EXT}"

  if [[ ! -f "$src_file" ]]; then
    warn "Source not found, skipping: $src_file"
    return 0
  fi

  if [[ $FORCE -eq 0 && -f "$out_file" ]]; then
    warn "Already exists (use --force to overwrite): $out_file"
    return 0
  fi

  local prop_lines=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && prop_lines+=("$line")
  done < <(parse_props "$src_file" "$name")

  if [[ $VERBOSE -eq 1 ]]; then
    if [[ ${#prop_lines[@]} -eq 0 ]]; then
      verbose "No props parsed for $name"
    else
      for p in "${prop_lines[@]}"; do
        verbose "prop: $p"
      done
    fi
  fi

  local has_children=0
  grep -q "children" "$src_file" 2>/dev/null && has_children=1

  if [[ $DRY_RUN -eq 1 ]]; then
    info "Would write: $out_file  (${#prop_lines[@]} props)"
    return 0
  fi

  {
    if [[ "$EXT" == "tsx" ]]; then
      echo "import type { Meta, StoryObj } from '@storybook/react';"
    else
      echo "/** @type {import('@storybook/react').Meta} */"
    fi

    echo "import { ${name} } from 'lily-design-system-react-headless';"
    echo ""

    if [[ "$EXT" == "tsx" ]]; then
      echo "const meta: Meta<typeof ${name}> = {"
    else
      echo "const meta = {"
    fi

    echo "  title: 'Components/${name}',"
    echo "  component: ${name},"
    echo "  tags: ['autodocs'],"

    if [[ ${#prop_lines[@]} -gt 0 ]]; then
      build_arg_types "${prop_lines[@]}"
      build_default_args "${prop_lines[@]}"
    elif [[ $has_children -eq 1 ]]; then
      echo "  args: { children: 'Content' },"
    fi

    echo "};"
    echo ""
    echo "export default meta;"

    if [[ "$EXT" == "tsx" ]]; then
      echo "type Story = StoryObj<typeof ${name}>;"
    fi

    echo ""
    echo "export const Default: Story = {};"

    if [[ ${#prop_lines[@]} -gt 0 ]]; then
      build_variant_stories "${prop_lines[@]}"
    fi

  } > "$out_file"

  ok "${name}  →  ${out_file}  (${#prop_lines[@]} props)"
}

# ── Resolve component list ────────────────────────────────────────────────────
if [[ ${#TARGETS[@]} -gt 0 ]]; then
  COMPONENTS=("${TARGETS[@]}")
else
  COMPONENTS=()
  while IFS= read -r f; do
    base=$(basename "$f" .tsx)
    COMPONENTS+=("$base")
  done < <(find "$SRC_DIR" -maxdepth 1 -name "*.tsx" ! -name "*.test.tsx" | sort)
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}lily-design-system story generator${RESET}"
echo -e "  Source     : $SRC_DIR"
echo -e "  Output     : $OUT_DIR"
echo -e "  Components : ${#COMPONENTS[@]}"
echo -e "  Extension  : .$EXT"
[[ $DRY_RUN -eq 1 ]] && echo -e "  ${YELLOW}Dry run — no files will be written${RESET}"
echo ""

# ── Run ───────────────────────────────────────────────────────────────────────
PASS=0; FAIL=0; SKIP=0

for name in "${COMPONENTS[@]}"; do
  result=$(generate_story "$name" 2>&1) || { ((FAIL++)) || true; echo "$result"; continue; }
  echo "$result"
  if echo "$result" | grep -q "^$(echo -e "${GREEN}✓")"; then
    ((PASS++)) || true
  else
    ((SKIP++)) || true
  fi
done

# ── Report ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Done.${RESET}"
[[ $PASS -gt 0 ]]  && echo -e "  ${GREEN}✓ $PASS written${RESET}"
[[ $SKIP -gt 0 ]]  && echo -e "  ${YELLOW}~ $SKIP skipped${RESET}"
[[ $FAIL -gt 0 ]]  && echo -e "  ${RED}✗ $FAIL failed${RESET}"
echo ""

[[ $FAIL -gt 0 ]] && exit 1 || exit 0