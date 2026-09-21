def main [--push-twc --push-fatp, --rebuild] {
    let initialPath = $env.PWD
    if $push_fatp {
        cd $env.FRONTARMTOPLANE_PATH
        git push -u origin main
    }
    cd $env.THATWATERCHARMANDER_PATH
    nix flake update frontArmToPlane
    git add ./flake.lock
    try { git commit -m "updating lockfile's frontArmToPlane input" ./flake.lock }
    if $push_twc {
        git push -u origin main
    }
    if $rebuild {
        sudo nixos-rebuild switch --flake .#wranHearst
    }
    systemctl --user start shellCacher-sieyesShell.service #re-cache sieyesShell
    cd $initialPath
}
