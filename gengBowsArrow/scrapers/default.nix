inputs:
inputs.baseLib.importPairsOfDirPath {
  dirPath = ./.;
  pred = x:
    (dirOf x == ./.) && baseNameOf x != "default.nix";
  inputsForImportPairs = inputs;
  excludeDirectories = false;
}
