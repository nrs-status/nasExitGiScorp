#!/usr/bin/env nu

# Scan the LAN for reachable hosts **without root**, resolve their host
# names through the router's DNS, and flag the target host
# (default: lanchamarcou).
#
# Technique: a raw ARP sweep (arp-scan) needs root, so instead we trigger
# ARP resolution for every address of the local subnet with unprivileged
# pings (resolved to the setuid NixOS ping wrapper via PATH), then read
# the kernel's neighbour (ARP) table with `ip neigh`. Hosts that drop
# ICMP still appear as long as they answered the ARP request.
#
# Usage:
#   scan-lan                 # look for "lanchamarcou"
#   scan-lan otherhost       # look for "otherhost"
#   scan-lan --router 192.168.2.1

def ip-to-int [ip: string] {
    $ip | split row '.' | reduce --fold 0 {|octet, acc|
        ($acc * 256) + ($octet | into int)
    }
}

def int-to-ip [n: int] {
    [
        ($n / 16777216 | math floor | into int)
        (($n mod 16777216) / 65536 | math floor | into int)
        (($n mod 65536) / 256 | math floor | into int)
        ($n mod 256)
    ] | str join '.'
}

def main [
    target: string = "lanchamarcou"   # host name to detect
    --router: string = "192.168.2.1"  # router / DNS server IP
] {
    # --- find our own IPv4 address and prefix length --------------------
    print "Discovering local subnet..."
    let addr_line = (ip -4 -o addr show scope global
        | lines
        | where {|l| $l =~ 'inet\s'}
        | get 0? | default "")

    if $addr_line == "" {
        print -e "No global IPv4 address found on any interface."
        exit 1
    }

    let cidr = ($addr_line | split row -r '\s+'
        | where {|p| $p =~ '^\d+\.\d+\.\d+\.\d+/\d+$'}
        | get 0)
    let my_ip = ($cidr | split row '/' | get 0)
    let prefix = ($cidr | split row '/' | get 1 | into int)
    let host_bits = (32 - $prefix)
    let block = (2 ** $host_bits)

    if $block > 65536 {
        print -e $"Subnet \/(($prefix)) is too large to sweep \(($block) addresses\). Aborting."
        exit 1
    }

    # network base address, computed without bitwise ops
    let net_int = ((ip-to-int $my_ip) - ((ip-to-int $my_ip) mod $block))

    # --- ARP sweep via unprivileged pings -------------------------------
    print $"Pinging ($block - 2) hosts to fill the ARP cache \(no root needed\)..."
    let _ = (1..($block - 2) | each {|i| int-to-ip ($net_int + $i) } | par-each {|ip|
        ping -c 1 -W 1 $ip | complete
        null
    })

    # --- read the kernel neighbour (ARP) table --------------------------
    print "Reading ARP cache..."
    let raw = (ip neigh show | complete)

    if $raw.exit_code != 0 {
        print -e $"ip neigh failed: ($raw.stderr | str trim)"
        exit 1
    }

    let hosts = ($raw.stdout
        | lines
        | where {|l| ($l =~ '^\d+\.\d+\.\d+\.\d+\s') and ($l =~ 'lladdr')}
        | parse -r '^(?<ip>\d+\.\d+\.\d+\.\d+)\s+dev\s+\S+\s+lladdr\s+(?<mac>\S+)'
        | uniq-by ip)

    if ($hosts | is-empty) {
        print "No hosts found."
        return
    }

    # Resolve each discovered IP through the router's DNS
    let with_names = ($hosts | each {|h|
        let name = (dig +short +time=1 +tries=1 @($router) -x $h.ip
            | complete | get stdout
            | lines | get 0? | default "" | str trim | str replace -r '\.$' '')
        {
            ip: $h.ip
            mac: $h.mac
            name: (if $name == "" { "--" } else { $name })
        }
    })

    let sorted = ($with_names | sort-by ip)
    print ($sorted | table)

    let hits = ($sorted | where {|h| ($h.name | str lowercase | str contains ($target | str lowercase))})
    if ($hits | is-empty) {
        print $"==> No host matching '($target)' found."
    } else {
        for h in $hits {
            print $"==> FOUND: ($h.ip) — host name: ($h.name)"
        }
    }
}
