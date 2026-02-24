id_to_name() {
  id=$1
  if [[ ! $id =~ ^-?[0-9]+$ ]]; then echo "bad machine ID: $id" >&2; return 1
  elif [[ $id -eq 0 ]]; then echo gateway
  elif [[ $id -le 3 ]]; then echo control$(($id - 1))
  elif [[ $id -le 6 ]]; then echo worker$(($id - 4))
  else echo "bad machine ID: $id" >&2; return 1
  fi
}

sedi() {
  case $(uname -s) in
    Linux) sed -i $*;;
    Darwin) sed -i '' $*;;
  esac
}

# Returns a space-separated list of upstream DNS servers
get_upstream_dns() {
    local dns_servers=()

    # 1. Try resolvectl (Standard on modern Ubuntu/Systemd systems)
    if command -v resolvectl >/dev/null 2>&1; then
        # Extract DNS servers, excluding local stub addresses
        local resolved_dns
        resolved_dns=$(resolvectl dns | awk '{print $4}' | grep -vE '^127\.|^::1' | xargs)
        if [[ -n "$resolved_dns" ]]; then
            dns_servers+=($resolved_dns)
        fi
    fi

    # 2. Fallback: Parse /etc/resolv.conf (Good for Arch or systems without active resolved)
    # We look for lines NOT containing 127.0.0.x
    local resolv_dns
    resolv_dns=$(grep '^nameserver' /etc/resolv.conf | awk '{print $2}' | grep -vE '^127\.|^::1' | xargs)
    if [[ -n "$resolv_dns" ]]; then
        dns_servers+=($resolv_dns)
    fi

    # 3. Last Resort: Public DNS (Ensures something is always there)
    dns_servers+=(8.8.8.8 1.1.1.1)

    # Return unique values
    echo "${dns_servers[@]}" | tr ' ' '\n' | sort -u | xargs
}

# Downloads files via wget with per-URL retries and verbose logging.
#
# Usage: wget_retry [OPTIONS] URL [URL...]
#   -P DIR   Download into DIR (wget -P)
#   -O FILE  Save as FILE (wget -O); disables --timestamping
#   -r N     Max attempts per URL (default: 3)
#   -d N     Seconds between retries (default: 5)
wget_retry() {
  local out_dir="" out_file="" max_retries=3 delay=5
  local wget_opts=(--show-progress --https-only --timestamping)

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -P) out_dir="$2"; shift 2 ;;
      -O) out_file="$2"; shift 2 ;;
      -r) max_retries="$2"; shift 2 ;;
      -d) delay="$2"; shift 2 ;;
      -*) echo "[wget_retry] ERROR: unknown option: $1" >&2; return 1 ;;
       *) break ;;
    esac
  done

  if [[ -n "$out_file" ]]; then
    wget_opts=(--show-progress --https-only)
  fi

  local urls=("$@")
  if [[ ${#urls[@]} -eq 0 ]]; then
    echo "[wget_retry] ERROR: no URLs provided" >&2
    return 1
  fi

  local failed=0
  for url in "${urls[@]}"; do
    local filename
    filename=$(basename "$url")
    local attempt=0
    local success=false

    while [[ $attempt -lt $max_retries ]]; do
      attempt=$((attempt + 1))
      echo "[wget_retry] ($attempt/$max_retries) Downloading: $filename"
      echo "[wget_retry]   URL: $url"

      local cmd=(wget)
      cmd+=("${wget_opts[@]}")
      if [[ -n "$out_dir" ]]; then
        cmd+=(-P "$out_dir")
      fi
      if [[ -n "$out_file" ]]; then
        cmd+=(-O "$out_file")
      fi
      cmd+=("$url")

      if "${cmd[@]}"; then
        echo "[wget_retry] OK: $filename downloaded successfully."
        success=true
        break
      else
        local rc=$?
        echo "[wget_retry] WARN: attempt $attempt/$max_retries failed for $filename (wget exit code: $rc)" >&2
        if [[ $attempt -lt $max_retries ]]; then
          echo "[wget_retry]   Retrying in ${delay}s..." >&2
          sleep "$delay"
        fi
      fi
    done

    if [[ "$success" != true ]]; then
      echo "[wget_retry] ERROR: giving up on $filename after $max_retries attempts." >&2
      echo "[wget_retry]   URL: $url" >&2
      failed=1
    fi
  done

  return $failed
}