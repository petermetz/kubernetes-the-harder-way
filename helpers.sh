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