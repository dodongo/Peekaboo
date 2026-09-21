---
summary: 'Select a substring or place the cursor in an accessibility text field'
read_when:
  - 'editing part of a text field without replacing its entire value'
---

# `peekaboo select-text`

Selects one exact substring in a readable, non-secure AX text field or text area.
It uses the element's settable selected-text range, without changing its text.
Bridge protocol 1.39 is required. Unsupported fields and ambiguous matches fail
before dispatch; use adjacent `--prefix` and/or `--suffix` to disambiguate.

```sh
peekaboo select-text "target" --on "$ELEMENT_ID" --snapshot "$SNAPSHOT_ID"
peekaboo select-text "target" --prefix "second " --selection-type cursor_after \
  --on "$ELEMENT_ID" --snapshot "$SNAPSHOT_ID"
```

`--selection-type` accepts `text` (default), `cursor_before`, or `cursor_after`.
Prefix/suffix identify the match and are not selected. Matching uses UTF-16 ranges,
including text after emoji and other non-ASCII content.

Use fresh snapshot and app/window targeting as for `set-value`. Selection uses the
same process-generation validation, mutation lease, target receipt and canonical
outcome contract. An accepted write with failed readback is indeterminate and
retry-unsafe; observe again before retrying. Secure fields are refused. JSON
`newValue` is the selected text, or an empty string for a cursor, not the full field
value. Available AX actions are exposed as `actions` in `see` JSON observations.
