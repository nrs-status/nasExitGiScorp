# SPEC: jev

## 0. About this document

This is a **very high-level specification document**. It deliberately omits
all information about tooling, libraries, packaging and file layout, and
describes only the essential types and the program logic of `jev`. It is not
a build guide and it is not an API reference; it is the contract the program
is expected to satisfy.

## 1. Purpose

`jev` is a small command-line program with a single job:

1. It reads one JSON object from its standard input.
2. It sends that object to OpenRouter's **Jev** model.
3. It writes the model's JSON reply to its standard output.

There is no other output on standard output, and no interactive behaviour.

## 2. Configuration

Three settings control the request. Each is resolved with the same
precedence rule: **command line option > environment variable > built-in
default**.

| Setting      | Command line option | Environment variable | Default                                   |
|--------------|---------------------|----------------------|-------------------------------------------|
| API key file | `--api-key-file`    | `OPENROUTER_API_KEY` | `/run/secrets/keys/openrouter`            |
| Jev model    | `--model`           | `DEFAULT_JEV_MODEL`  | `~typesafe/jev-latest`                    |
| Endpoint     | `--api-url`         | `JEV_API_URL`        | `https://openrouter.ai/api/alpha/decisions` |

* The API key file path names a file whose contents (one line) are the
  OpenRouter API key. The key itself is never printed, stored or logged.
* The Jev model is the model id placed in the request (see §4).
* An empty command line option or environment variable is treated as absent,
  i.e. it does not override the next source in the chain.

## 3. Types

### 3.1 `Request`

A JSON object. It is the body of the request to the Jev model. The program
does not interpret any of its fields, except that it **sets the `model`
field** to the resolved Jev model (§2). Any `model` already present in the
input is overwritten: the model is owned by the program's configuration, not
by the caller's input.

The Jev model is a *decisions* model, so a meaningful request carries the
fields that API expects, most importantly:

* `state` — the situation the model reasons about, and
* `questions` — the questions to answer about that state.

### 3.2 `Response`

A JSON object produced by the Jev model. The program does not interpret it;
it is forwarded to standard output verbatim. On success it typically carries
the fields `model`, `answers`, `usage`, `id` and `provider`; on failure it
carries an `error` field.

### 3.3 `Config`

The triple (`apiKeyFile`, `model`, `endpoint`) obtained from §2.

## 4. Program logic

1. **Read.** Read all of standard input and parse it as JSON. The value must
   be an object; anything else (including malformed JSON) is an error.
2. **Resolve.** Compute the `Config` from the command line options,
   environment variables and defaults according to §2.
3. **Authenticate.** Read the OpenRouter API key from the configured file.
   An unreadable file is an error.
4. **Prepare.** Set the request's `model` field to the configured Jev model.
5. **Send.** `POST` the prepared request as JSON to the configured endpoint,
   with the API key in the `Authorization: Bearer …` header.
6. **Answer.** Write the endpoint's response body to standard output,
   followed by a newline if the body does not already end in one.
7. **Exit.**
   * status `0` if the endpoint answered with a 2xx status;
   * status `1` on any error, after writing a short `jev: error: …` message
     to standard error.

## 5. Errors

Each of the following is a fatal error (message on standard error, exit
status `1`):

* the standard input is not valid JSON, or is not a JSON object;
* the API key file cannot be read;
* the endpoint answers with a non-2xx status (the response body is still
  written to standard output first);
* the endpoint cannot be reached.

## 6. Example

Input:

```json
{
  "state": "The user greets you.",
  "questions": {
    "greeting": {
      "type": "noul",
      "instructions": "Respond with a short greeting."
    }
  }
}
```

Output (shape; values vary):

```json
{
  "model": "typesafe/jev-1.13-20260917",
  "answers": { "greeting": { "type": "noul", "noul": 0.82 } },
  "usage": { "input_tokens": 278, "output_tokens": 20, "cost": 0.000011676 },
  "id": "gen-dec-…",
  "provider": "TypeSafe"
}
```
