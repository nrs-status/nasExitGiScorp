def getPinInfo [uri, dirtyRevPath?: path] {
    nix flake metadata --json $uri
    | from json
    | do {
        let rev = (
            if "dirtyRevision" in $in { git -C $dirtyRevPath rev-parse HEAD~1 } else { $in.revision }
        )
        let lastModified = $in.lastModified | into datetime -f "%s"
        {rev: $rev, lastModified: $lastModified}
    }
}

{
    frontArmToPlane: {
        registry: (nix registry list | where flakeref == "flake:frontArmToPlane" | reject flakeref | do {
    let flakes = $in
    let userFlakePinInfo = if "user" in $flakes.owner { getPinInfo $env.FRONTARMTOPLANE_PATH $env.FRONTARMTOPLANE_PATH | wrap user } else {}
    let systemFlakePinInfo = getPinInfo ($flakes | where owner == "system" | get uri.0)
    $userFlakePinInfo | merge { system : $systemFlakePinInfo }
  })

        local: (getPinInfo $env.FRONTARMTOPLANE_PATH $env.FRONTARMTOPLANE_PATH)
        local_twc_input: (
            nix flake metadata --json /home/sieyes/baghdad_plane/flakes/newThatWaterCharmander/
            | from json
            | get locks.nodes.frontArmToPlane.locked
            | select rev lastModified
            | update lastModified { into datetime -f "%s" }
        )
        remote: (getPinInfo github:nrs-status/newFrontArmToPlane)
    }
}
