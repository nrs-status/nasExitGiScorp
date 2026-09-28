{ pkgs, ... }:
# rag: configurable retrieval-augmented-generation agent over a set of
# documents, driven by OpenRouter; see ./SPEC.md for the behavioural spec.
#
# usage:
#   rag [--config <file.toml>] [question ...]   (no question: interactive)
#
# The config path comes from --config, else $RAG_CONFIG (the command line
# option wins); see ./example.toml for a commented reference configuration.
#
# The TOML configuration selects the models (embedding / chat / vision), the
# documents (files or directories) and the API key file. Supported inputs:
# PDF, DjVu ("DejaVu"), docx, txt/md/csv/json/html/... text formats,
# xlsx/xlsm/xls spreadsheets, and images (png, jpg, gif, webp, bmp, tiff).
let
  py = pkgs.python3Packages;
  script =
    builtins.replaceStrings
      [ "@DJVUTXT@" "@DDJVU@" ]
      [ "${pkgs.djvulibre}/bin/djvutxt" "${pkgs.djvulibre}/bin/ddjvu" ]
      (builtins.readFile ./rag.py);
in
pkgs.writers.writePython3Bin "rag"
  {
    libraries = [
      py.requests
      py.pypdf
      py.python-docx
      py.openpyxl
      py.xlrd
      py.pillow
    ];
    flakeIgnore = [
      "E501" # line too long (docstring/comments)
      "E265" # block comment should start with '# '
      "W503" # line break before binary operator
    ];
  }
  script
