# Browser command stream

`peekaboo browser stream --page-id <observed-id> --foreground --json` runs ordinary
CLI browser calls in one process through the selected runtime. It requires a
confirmed existing connection and uses the same BrowserTool, execution policy,
page routing, mutation coordination and result envelopes as standalone commands.
It does not open an MCP browser session or reuse another caller's scoped session.

The first stdout line is `{"ready":true,"protocol":"peekaboo-browser-stream-1"}`.
Send one JSON object followed by a newline, then consume its response before
sending the next request. Read fresh snapshot UIDs before dependent actions.
Example requests:

```json
{"action":"snapshot"}
{"action":"click","uid":"<fresh uid>","include_snapshot":true}
```

Actions are `snapshot`, `click`, `fill`, `fill_form`, `hover`, and `call`.
Request fields are `action`, `uid`, `value`, `include_snapshot`, `mcp_tool`, and
`mcp_args_json`, using BrowserTool's existing types and semantics. Raw `call`
permits only `take_snapshot`, `evaluate_script`, `press_key`, `type_text`, `wait_for`, and
`peekaboo_locator_action` (requires an updated host); the provider's
page routing and validation still apply. Foreground authority comes from the
explicit command flag, never from request JSON. Connection and tab-management
operations are unavailable; requests cannot override page, channel or policy.

Protocol 1.40 hosts validate the initial connection receipt and provider epoch
atomically with each execution, avoiding repeated client-side status calls.
Older hosts retain the per-request status checks. No new request fields or
agent-facing tools are needed.

Each request is at most 1 MiB; a process accepts at most 256 requests. EOF ends
the stream. An incomplete line, invalid request, tool failure or changed
connection receipt/provider epoch stops it. Error envelopes preserve original
receipts. Do not replay a request after a timeout or disconnect: it may have
executed. Retain the result and reobserve before choosing recovery. The caller
must enforce a timeout and close its child process when done.

This candidate API has build, parser/open-pipe and live grouped-form coverage.
The dotfiles batch helper exposes it through `--transport stream`. Three paired
fixture runs had a1,929ms stream median versus2,236ms CLI median with verified
results. This narrow fixture measurement is not a general latency guarantee.
The installed pinned CLI remains unchanged.
