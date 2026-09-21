#!/usr/bin/env bash
# img-builder — build a minimal, non-graphical NixOS installer ISO that
# tries to connect to a given WiFi network at boot and sets root's password.
# The `nixos` user is logged in automatically into a shell that echoes the
# state of the WiFi connection until connected; root's shell is left
# untouched (it is used by nixos-everywhere to install NixOS).
#
# Usage:
#   img-builder --ssid SSID --password PASSWORD [-o OUT] [--dry-run]
#   img-builder --ssid SSID --wifi-password PW --root-password PW [-o OUT] [--dry-run]
#   img-builder SSID PASSWORD [-o OUT] [--dry-run]     # positional form
#
# --password (or the positional PASSWORD) is shorthand for giving the same
# value as both --wifi-password and --root-password.
#
# The produced ISO is a very simple extension of the official minimal NixOS
# installer (see ./iso.nix).
set -euo pipefail

die() { printf '%s\n' "img-builder: error: $*" >&2; exit 1; }
usage() {
  cat <<'EOF'
usage: img-builder --ssid SSID --password PASSWORD [-o OUT] [--dry-run]
       img-builder --ssid SSID --wifi-password PW --root-password PW [-o OUT] [--dry-run]
       img-builder SSID PASSWORD [-o OUT] [--dry-run]

Builds a minimal non-graphical NixOS installer ISO that tries to connect to
the WiFi network SSID at boot, and on which root's password is set.  The
`nixos` user autologins into a shell echoing the WiFi connection state;
root's shell is left untouched (used by nixos-everywhere).

--password (or the positional PASSWORD) is shorthand for using the same
value as both the WiFi password and root's password; use --wifi-password
and --root-password to set them separately.

options:
  -s, --ssid SSID            WiFi network name (required)
  -p, --password PASSWORD    shorthand: use PASSWORD as both the WiFi
                             password and root's password
  -w, --wifi-password PW     WiFi password
  -r, --root-password PW     root password on the installer
  -o, --out-link OUT         symlink target for the build result
                             (default: ./nixos-wifi-installer-iso)
      --dry-run              evaluate the ISO derivation without building it
  -h, --help                 show this help
EOF
}

ssid=""
password=""
wifiPassword=""
rootPassword=""
outLink=""
dryRun=""

while [ $# -gt 0 ]; do
  case "$1" in
    -s|--ssid)
      [ $# -ge 2 ] || die "--ssid requires an argument"
      ssid="$2"; shift 2 ;;
    -p|--password)
      [ $# -ge 2 ] || die "--password requires an argument"
      password="$2"; shift 2 ;;
    -w|--wifi-password)
      [ $# -ge 2 ] || die "--wifi-password requires an argument"
      wifiPassword="$2"; shift 2 ;;
    -r|--root-password)
      [ $# -ge 2 ] || die "--root-password requires an argument"
      rootPassword="$2"; shift 2 ;;
    -o|--out-link)
      [ $# -ge 2 ] || die "--out-link requires an argument"
      outLink="$2"; shift 2 ;;
    --dry-run)
      dryRun="1"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift; break ;;
    -*)
      usage >&2; die "unknown option: $1" ;;
    *)
      # positional argument (SSID first, then PASSWORD)
      if [ -z "$ssid" ]; then ssid="$1"
      elif [ -z "$password" ]; then password="$1"
      else
        usage >&2; die "unexpected extra argument: $1"
      fi
      shift ;;
  esac
done

[ -n "$ssid" ] || { usage >&2; die "no SSID given"; }
[ $# -eq 0 ] || { usage >&2; die "unexpected extra arguments: $*"; }

# --password (and the positional PASSWORD) is shorthand for the same value
# as both passwords; --wifi-password/--root-password override each role.
wifiPassword="${wifiPassword:-$password}"
rootPassword="${rootPassword:-$password}"
[ -n "$wifiPassword" ] || { usage >&2; die "no WiFi password given (use --password or --wifi-password)"; }
[ -n "$rootPassword" ] || { usage >&2; die "no root password given (use --password or --root-password)"; }

# Baked in at package build time by the substitute in ./default.nix.
nixpkgsPath="@nixpkgsPath@"
isoNix="@isoNix@"

[ -f "$isoNix" ] || die "missing $isoNix"

# Hash the root password for root's hashedPassword (yescrypt, same as
# mkpasswd default used by passwd on modern NixOS).
hashedPassword="$(printf '%s' "$rootPassword" | mkpasswd -m yescrypt --stdin)"
[ -n "$hashedPassword" ] || die "mkpasswd failed"

# Compute the WPA pre-shared key (pskRaw) so the raw WiFi password does not
# end up in the wpa_supplicant config of the ISO.
psk="$(wpa_passphrase "$ssid" "$wifiPassword" 2>/dev/null | sed -n 's/^[[:space:]]*psk=//p')"
[ -n "$psk" ] || die "wpa_passphrase failed (is the password 8-63 characters?)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
jq -n --arg ssid "$ssid" --arg psk "$psk" --arg hashedPassword "$hashedPassword" \
  '{ ssid: $ssid, psk: $psk, hashedPassword: $hashedPassword }' \
  > "$tmp/wifi.json"

nixArgs=(
  --extra-experimental-features "nix-command"
  -f "$isoNix"
  --argstr nixpkgsPath "$nixpkgsPath"
  --argstr wifiJson "$tmp/wifi.json"
  -L
)

if [ -n "$dryRun" ]; then
  echo "img-builder: dry run — evaluating the ISO derivation (not building)" >&2
  exec nix build "${nixArgs[@]}" --dry-run --no-link
fi

echo "img-builder: building minimal WiFi installer ISO for ssid '$ssid'" >&2
echo "img-builder: this can take a while (several minutes to ~1h)" >&2
nix build "${nixArgs[@]}" --out-link "${outLink:-nixos-wifi-installer-iso}"
result="$(readlink -f "${outLink:-nixos-wifi-installer-iso}")"
echo "img-builder: done — ISO at $result"
printf '%s\n' "$result"