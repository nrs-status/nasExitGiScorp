# SPEC: rag

`rag [--config FILE.toml] [question ...]` loads the documents named in the TOML
config, indexes them with an embedding model, retrieves the top-k chunks for a
question by cosine similarity, and has a chat model answer from them. With no
question it reads questions interactively from stdin.

The config file path is taken from `--config`, else the `RAG_CONFIG`
environment variable (the option wins); if neither is set, or the file cannot
be read or parsed, `rag` exits with an error. `example.toml` is a commented
reference configuration for human readers.

Config (relative paths resolve against the config file directory):
`api_key_file` (default `/run/secrets/keys/openrouter`); `[models]`
`chat`, `embedding`, `vision`; `[documents] paths` (files or directories,
recursive); `[agent]` `top_k`, `chunk_size`, `chunk_overlap`, `system_prompt`,
`api_url`, `ipv4_only` (default `true`: connect over IPv4 only, since IPv6 is
blackholed on the target network; `false` allows IPv6). CLI `--api-key-file` and `--chat-model` override the config.

Formats: PDF (text layer; images on scanned pages, and images of at least
300x300 px on text pages, are described by the vision model; empty-password
encryption is handled, other encrypted or corrupt PDFs are skipped), DjVu (text layer, else rendered
and sent to vision model), docx, text formats (txt, md, csv, json, html, ...),
spreadsheets (xlsx, xlsm, xls), images (png, jpg, gif, webp, bmp, tiff; via
vision model). Unreadable files are skipped with a warning on stderr.
