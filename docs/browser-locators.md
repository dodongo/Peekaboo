# Provider locator actions

The updated provider bootstrap adds `peekaboo_locator_action`. It requires a host
running this source; older installed hosts do not expose the tool. It is routed
to an explicit page, classified as mutating and requires foreground authority. Pointer/keyboard
actions use trusted input; select uses native option state with synthetic events.

```sh
peekaboo browser call --page-id "$page" --foreground \
  --mcp-tool peekaboo_locator_action \
  --mcp-args-json '{"query":{"label":"Full name"},"action":"fill","value":"Ada","includeSnapshot":true}' \
  --json
```

Queries use `css`, `label`, `placeholder`, `testId`, or `role` with optional `name`. Each scope and the
final target must resolve uniquely. `within` accepts up to eight nested selectors;
`{"shadow":{"css":"my-app"}}` enters an open shadow root, and
`{"frame":{"css":"iframe"}}` resolves the frame through Puppeteer, including
cross-origin frames. Label matching uses associated labels and ARIA label
attributes, with references resolved in the element's own root. This is not a
complete accessible-name algorithm or an implicit shadow-piercing CSS engine.

For computed accessibility targeting, use `{"role":"button","name":"Save"}`.
The pinned Puppeteer AX query returns Chrome-computed roles/names and excludes
ignored nodes. Names are exact and case-sensitive; omission matches any name.
The scope itself is excluded. The query supports explicit frame and shadow
scopes and rejects multiple matches before input. Connected feature discovery
advertises `locator:role` when this query schema is available.

Queries and scopes accept `hasText`, `hasNotText`, and `nth`. Text filters are
case-insensitive literal substrings of normalized descendant `textContent`.
Filtering precedes occurrence selection: `nth: 0` selects the first match,
`nth: -1` the last, and other nonnegative values select that zero-based index.
Without `nth`, ambiguity remains an error. Missing occurrences participate in
the existing bounded presence wait. Use an index only when ordering is part of
the intended target. These refinements are advertised as `locator:refinements`.
AX candidate checks and refinements run in one page evaluation rather than one
round trip per candidate. Regex filters remain unsupported; structural filters are described below.

Actions are `click`, `dblclick`, `fill`, `hover`, `type`, `press`, `check`, `uncheck` and `select`; fill/type require `value`.
Type focuses an enabled editable element without clicking and inserts trusted
keyboard text at its current caret/selection. It supports text inputs, textareas
and contenteditable elements. Disabled, read-only, noneditable or unfocusable
targets fail before typing. Type polls target presence but not editable/focus readiness. Press requires a `key` (1–100 characters), such as
`Enter`, `Tab`, or `Control+Shift+ArrowLeft`. It focuses the uniquely resolved,
enabled target without clicking, then sends trusted keyboard events. Key names
are validated with the pinned provider parser before focus; combination prefixes
must be Control, Shift, Alt or Meta. All held modifiers get a release attempt
even after an input/release failure, which stops the operation without replay.
Press polls presence but not enabled/focus readiness.
`timeout` (1–20,000 ms, default 5,000) bounds presence polling for missing
scopes/targets. Each unsuccessful resolution releases its handles before the
next 100 ms poll. The remaining budget goes to the input locator readiness wait.
Only zero-match resolution retries: ambiguity, invalid selectors, inaccessible
boundaries and detachment fail immediately. Once input starts, presence polling
cannot replay it even if its error resembles a missing target. `includeSnapshot` returns post-action targeting evidence through the
normal provider response. Successful dispatch alone does not prove the user's
intended page state.

Resolution and action run under the existing provider tool mutex and explicit
page routing. Handles remain owned through the operation and are released on
success or failure. Detached/ambiguous scopes fail before dispatch; the wrapper
does not replay an operation after it fails. Pointer/keyboard input uses Puppeteer's trusted locator/keyboard methods.
Select uses verified option-state updates and synthetic input/change events. The pinned provider
registry is hash-checked before adding the tool.

Validation: `node --test scripts/test-browser-locator-resolver.mjs`,
`node --no-warnings scripts/test-chrome-devtools-mcp-contract.mjs`, and the Swift
`BrowserLocatorContractTests`/`BrowserToolCapabilityContractTests` suites.
For live provider validation, set `PEEKABOO_TEST_CHROME` to an installed Chrome
executable and run `node --no-warnings scripts/test-browser-locator-live.mjs`.
This launches a headless temporary profile and two local HTTP origins, then
verifies trusted fill/hover/click events through a cross-origin iframe and open
shadow root. It also verifies selection-preserving Unicode typing without input clicks,
disabled typing refusal, trusted ArrowRight/Shift+ArrowLeft selection, and that
ambiguity produces no input. It closes the
browser and fixtures afterward. It does not connect to the user's Chrome profile.

The live provider fixture passed. GUI-host activation and end-to-end batch
validation through the updated installed bridge remain pending.

`check` and `uncheck` accept no value or key. They support native checkboxes and
radios and ARIA checkbox/radio/switch controls. Already satisfied states do not
click. Otherwise a trusted click must produce the requested checked state;
failed or detached targets stop without replay. Mixed checkboxes may require a
second click only after the first produces a verified opposite boolean state.
Disabled transitions and attempts to uncheck a selected radio fail before input.
Choose another radio to change a radio group. Custom controls must expose a
valid `aria-checked` state; asynchronous state changes that have not settled by
the post-click read fail verification.

## Read-only evaluation latency

The pinned, hash-checked script adapter supports `skipNavigationWait: true` with
`waitForStableDom: false` for known read-only page/element evaluations. It omits
the 100 ms navigation-start probe, retaining normal result/file handling and
error cleanup. Conflicting settings and service-worker targets fail before
evaluation. Defaults remain unchanged. Arbitrary script evaluation remains
classified as mutating and requires foreground authority; the flag is a wait
policy, not a sandbox or proof of read-only behavior.

Dotfiles exposes this on its fixed DOM reader as `browser query
--skip-navigation-wait`; older GUI hosts reject the optional field.

## Discovering provider features

`browser status --json` reports `meta.provider_features` from the connected
provider's actual tool schemas, alongside its session epoch. Locator enum values
appear as `locator:<action>` and the read optimization as
`read:skipNavigationWait`. The list is deterministic and bounded to known
features. Confirmed disconnection returns an empty list; indeterminate status or
an older manager without feature information returns null. Text status includes
a compact Features line when connected. Never infer support from tool count or
reuse a feature observation after the provider session changes.

`dblclick` performs one trusted locator click with count 2. It accepts no value
or key and preserves click-detail/double-click event semantics; two separate
click operations are not equivalent. Its capability flag is `locator:dblclick`.

Clicks also accept optional `button` (`left`, `right`, `middle`) and `modifiers`
(up to four unique `Alt`, `Control`, `Meta`, `Shift`, `ControlOrMeta` entries).
`ControlOrMeta` resolves using the local provider platform; aliases that resolve
to duplicate keys are rejected before resolving a target. Nonclick actions
reject these fields. Advertised schema support yields `locator:clickOptions`.
Modifier keydown wraps the trusted locator click; every attempted modifier gets
a reverse-order release attempt on success or failure, including an uncertain
keydown reply. The first failure is retained and input is not replayed. Keypress
uses the same cleanup. Existing calls with omitted options retain their behavior.

The wire-schema regression starts the exact embedded provider on stdio and reads
MCP `tools/list`, without requesting a Chrome connection:

```sh
node --no-warnings scripts/test-browser-provider-schema.mjs
```

This check is included in `test:safe`. To additionally verify that native feature
discovery decodes those actual wire records (rather than hand-written fixtures):

```sh
schema_file=$(mktemp)
node --no-warnings scripts/test-browser-provider-schema.mjs --json > "$schema_file"
PEEKABOO_PROVIDER_SCHEMA_FIXTURE="$schema_file" swift test --package-path Core/PeekabooCore --filter BrowserProviderFeaturesTests
rm "$schema_file"
```

The wire-decoding Swift case is opt-in via this environment variable; normal
unit runs keep their in-memory fixtures and do not require a running Node provider.

`select` requires `options`: a value string, a value/label/index descriptor, or
an array of up to 50 entries. All descriptor fields must match one unique option;
value/label strings are bounded to 1,000 characters. Empty arrays clear selection.
Before mutation, all requested options must exist, be enabled and be distinct;
multiple entries require a multiple select. Input/change events are synthetic
and bubbling, created in the owning document's realm. The final selection is
verified after event handlers run; failures stop without replay. Presence waits
apply to the target, but option appearance/enabled readiness is checked once.
Capability discovery advertises `locator:select`. Existing UID selection remains
available for older hosts.

Associated label text excludes the target control’s own subtree, so option text
inside a wrapped select does not become part of its label. This remains a
focused label matcher, not the complete accessible-name algorithm.

Text selectors use `{text: "Save"}` for normalized, case-insensitive substring matching, or `exact: true` for case-sensitive whole-text matching. Matching ancestors yield to matching descendants; script/style/head content is excluded, and button/submit input values are included. Text queries share scopes and refinements with the other selectors. Provider discovery reports `locator:text`.

Query `visible: true` or `visible: false` filters before `nth`. Visibility requires CSS visibility and a nonzero bounding box, including each explicitly entered embedding frame. Opacity is not considered. Ambiguity still fails; filtering never implies selecting the first match. Provider discovery reports `locator:visibility`.

`has` and `hasNot` accept relative descendant DOM queries, including nested filters
up to three levels. They run before `nth` and exclude the candidate itself.
Nested queries support CSS, text, label, placeholder and test ID. On hosts
advertising `locator:nestedRole`, they also support computed role/name queries. Use explicit `within` scopes
for frame/shadow transitions. Nested visibility checks include those embedding
frames. Each resolution stage permits 10,000 descendant checks; exhaustion fails
before input and is not retried as a missing target. Provider discovery reports
`locator:descendants`. No additional provider tool is registered.


`and`/`or` combine matches in the same scope, before outer refinements. Intersection
uses element identity; union deduplicates in document order. Use one operator per
level, within the shared three-level query-depth bound. Feature discovery reports
`locator:composition`. Nested computed role queries additionally require
`locator:nestedRole`; each distinct role/name pair is collected once per scope
resolution, and descendant role filters restrict candidates by DOM containment,
excluding the candidate itself. More than 10,000 AX candidates in one scope
resolution fails before dispatch. Ambiguity and failed operations are never retried.
