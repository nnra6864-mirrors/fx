# Share fx interaction semantics across remote terminal and HTML clients

Status: proposed. This RFC changes no supported API or runtime behavior.

## Problem and outcome

An application embedding fx should be able to keep a native agent inside a
sandbox while presenting either a terminal or an HTML conversation. Today the
terminal owns interactive command behavior that an ACP client cannot simply
reuse. An HTML application consequently invents a model picker, settings menu,
and slash-command dispatch table, or accidentally sends `/model` as an LLM
prompt. Those interfaces drift from fx and add maintenance for every command.

Provide an fx-owned interaction contract and a libfx client for that contract.
The backend owns command parsing, settings, sessions, permissions, and tools.
The client renders fx-defined semantic interaction state, with a supported
terminal presentation and an optional reference DOM presentation. An application
may style or replace rendering without reimplementing command behavior.

A native fx process stays attached across turns. Model requests, filesystem
operations, MCP, and long-running processes stay in the sandbox. The browser is
an interaction client, not a proxy through which each tool must execute.

## What exists today

Inspected against upstream commit `f4ea28b23764a67b9054b357b2e3ac81a12b9138`:

| Concern | Existing owner and limitation |
| --- | --- |
| Terminal SDK | [`createFxTerminal`](../sdk/fx-sdk.js) instantiates the terminal runtime, forwards terminal bytes and resize events, and owns subscription cleanup. It is not a renderer attached to a remote native session. |
| Headless SDK | [`createFxAgent`](../sdk/fx-sdk.js) starts an ACP runtime and exposes prompt, checkpoint, and close. Its internal `runtimeFactory` seam does not expose terminal command or semantic UI behavior. |
| Browser tools | [`runtime_profile.zig`](../src/core/hosts/runtime_profile.zig) disables native tools for WASM. [`js_host_workspace.zig`](../src/core/hosts/js_host_workspace.zig) and [`browser_shell.zig`](../src/tools/shell/browser_shell.zig) provide a bounded completion-only workspace boundary. Proxying `fetch` does not relocate the agent to the server. |
| Commands | [`command_specs.zig`](../src/core/slash_commands/command_specs.zig), [`command_router.zig`](../src/core/slash_commands/command_router.zig), and [`app_commands.zig`](../src/core/app/app_commands.zig) already own command discovery, parsing, and handlers. Handlers still interact with the application and presentation, so exporting the table alone is insufficient. |
| ACP | [`server.zig`](../src/acp/server.zig) supports session lifecycle, prompt/cancel, configuration options and modes; [`sessions.zig`](../src/acp/sessions.zig) owns session operations. There is no general interactive command dispatch method in the method table. Ordinary ACP intentionally ignores the private libfx host-tool capability. |
| Structured output | [`output_contracts.zig`](../src/core/output/output_contracts.zig) is an existing source for typed output rather than parsing ANSI or duplicating state. |

Names are versioned product behavior. Current main explicitly tests that `/model`
is valid and `/models` is not. A client must obtain names and aliases from fx,
including dynamically available commands, rather than preserve a historical
spelling locally. Unknown slash input must produce a command error, not a model
request. Explicit literal-text submission remains available.

## Scope

Support both terminal and HTML presentation of the same interaction semantics.
Reuse existing core owners rather than introduce another command implementation.
Keep the JS SDK dependency-free; a DOM renderer can be an optional separate
entry point without imposing a framework or browser runtime on headless users.

This is not a proposal for a general remote shell API, a new sandbox provider,
a React component library, or moving native tools into WASM. Existing local
`createFxAgent`, `createFxTerminal`, and ordinary ACP clients retain their current
contracts. It does not promise every command can run on every client: clipboard,
URL opening, terminal attachment, and other host effects require explicit
capabilities and an honest unsupported response.

## Ownership and presentations

```text
HTML view or terminal view
        |
libfx interaction client: view state, input, local navigation
        |
persistent authenticated transport
        |
fx interaction service: command router and interaction snapshots
        |
native fx core: session, config, permissions, model, tools
```

Product state remains in core. Extract presentation-independent operations from
application handlers incrementally; do not put session or settings logic in
`src/ui/`. Native terminal rendering and a remote HTML renderer consume the same
operation results and interaction snapshots. Existing terminal input editing and
ANSI rendering need not be rewritten at once.

There are two terminal paths:

1. Native fx through PTY/WebSocket already provides the existing terminal
   experience. This remains valid and does not depend on the proposed SDK.
2. A libfx terminal frontend can eventually consume the interaction controller
   remotely, keeping composer editing and menu navigation local. If reusing the
   terminal renderer requires a UI-only WASM artifact, it must not instantiate a
   second agent or use the browser tool profile for the remote session.

HTML is a first-class consumer, not an ANSI-to-DOM conversion. fx supplies the
command menu, accepted settings, picker descriptions, validation, and actions.
An optional fx-maintained DOM renderer supplies those controls so embedding apps
can use fx without designing a settings UI. Applications that render their own
transcript may mount that renderer for interaction surfaces only.

Whether a UI-only WASM build is worth its size and JSPI requirements remains an
implementation choice. The remote HTML transport client should not require JSPI.

## Proposed client surface

These names and TypeScript sketches are proposals, not currently available APIs.
The complete schemas would be reviewed separately before implementation.

```ts
interface FxTransport {
  send(message: string): Promise<void>;
  subscribe(listener: (message: string) => void): () => void;
  onClose(listener: (reason: string) => void): () => void;
  close(): Promise<void>;
}

type FxInput =
  | { kind: 'composer'; text: string; requestId: string }
  | { kind: 'literal-text'; text: string; requestId: string }
  | {
      kind: 'action';
      interactionId: string;
      revision: number;
      actionId: string;
      value?: string;
      requestId: string;
    };

interface FxInteractionClient {
  submit(input: FxInput): Promise<void>;
  cancel(operationId: string): Promise<void>;
  subscribe(listener: (state: FxInteractionSnapshot) => void): () => void;
  close(): Promise<void>;
}
```

A proposed `connectFxInteraction({ transport, session, host })` negotiates and
attaches the controller. The transport interface intentionally contains no
credentials, model implementation, filesystem API, or sandbox lifecycle API.
An embedding app creates/authenticates its socket; fx handles the protocol.

`FxInteractionSnapshot` would be a bounded, versioned schema covering transcript
updates, command descriptors, accepted configuration, active operation, and a
discriminated interaction union: picker, form, confirmation, notice, and host
request. Each interaction has an opaque ID, revision, title, typed fields or
choices, and allowed action IDs. Validation and action meaning belong to fx.
Permission requests keep their existing exact option identifiers and semantics;
they are never reduced to a generic boolean confirmation.

The SDK owns generic presentation state such as focus, current search text, and
selection. A renderer sends actions through the controller, not arbitrary RPC
methods obtained from model text. Choice activation submits an opaque action and
revision. The backend rejects stale, unauthorized, or unknown actions and returns
the current state. Settings become durable only after existing fx persistence
accepts them; the UI must not optimistically claim success.

## Protocol and capabilities

Build on ACP for prompt streaming, lifecycle, configuration, and permission
requests. Add a negotiated, versioned fx extension for interaction discovery,
command submission, action responses, and snapshots. Exact extension method names
and placement must follow the ACP extension rules current at implementation;
this RFC does not claim these are standard ACP methods.

The handshake advertises schema versions, backend command capabilities, supported
interaction kinds, and host effects. Command descriptors come from the active fx
registry and include canonical names, aliases, availability, and disabled reasons.
Changes to workspace, authentication, plugins, or session refresh the descriptors.
Do not embed a generated but independently maintained second command registry in
JavaScript. A versioned backend snapshot may be cached for local completion.

The backend remains the authoritative parser on submission. Local completion,
menu navigation, and filtering require no network request. Large catalogs may be
paged explicitly; remote filtering shows pending state and ignores stale replies.
An unsupported schema or effect is visible before activation where possible, and
is checked again by the backend. No silent downgrade sends a command to the LLM.

For the native-sandbox profile, do not advertise ACP client filesystem or terminal
execution merely because the host is a browser. Tools execute natively beside the
agent. Explicit UI host effects such as opening an approved login URL or copying
text are separate from execution tools and require declared host support.

## Lifecycle, concurrency, and latency

The backend is authoritative for session identity, transcript, configuration,
permissions, and operation state. Browser storage may retain an opaque session
reference, not a competing checkpoint or provider credential. Attach uses an
explicit session ID; it must not choose an unrelated globally latest session.

Keep one active operation per session initially, consistent with current ACP's
connection model. Terminal and HTML may use independent sessions. They must not
mutate one saved session through unrelated processes concurrently. Shared-session
presentation requires one owner service with an exclusive writer lease or an
explicit transfer; read-only observers can be added separately.

Disconnect is not implicitly cancel, and reconnect is not implicitly retry.
Negotiate a bounded disconnect policy. Cancel targets an operation ID, is
idempotent, and settles outstanding interaction requests according to existing
permission and cancellation rules. Reconnect returns authoritative state plus a
sequence cursor. A client deduplicates replayed events. If the replay window has
expired, obtain a snapshot before accepting more actions. Exactly-once model
execution is not promised: the backend deduplicates recent request IDs, and an
uncertain expired request is reported rather than automatically resubmitted.

Sandbox provisioning, binary installation, and backend attachment occur at session
startup or explicit recovery. No turn should require those operations again.
While connected, input travels directly to the existing process; native tool
execution does not require browser round trips. This removes avoidable work, but
does not promise zero network latency or faster provider inference.

Expose separate timings for provisioning, attachment, submit-to-acceptance,
first agent event, first text, and rendering. First text is not necessarily the
provider's first token. Use monotonic durations within each clock domain and
correlation IDs across domains rather than subtract unsynchronized clocks. Test
local menu/input latency separately from remote work; do not introduce keep-warm
traffic as a substitute for correct lifecycle management.

## Security and compatibility

The application authenticates the user and authorizes the sandbox and session
before opening a connection. Use TLS, exact Origin validation for browser sockets,
short-lived scoped connection credentials, bounded frames and buffers, and
backpressure. Prefer credentials that can be supplied without long-lived URL
secrets; never log token-bearing URLs. The gateway must not accept arbitrary
workspace paths or executable names from the browser.

Keep provider credentials, native profile state, and tool execution in the
sandbox. Interaction text, command output, model output, and repository content
are untrusted display data: render text safely, validate URLs, and never treat
embedded strings as action authority. Actions require a live server-issued
interaction ID, revision, and advertised action. Backend permission policy always
applies; neither UI nor transport selects a permission bypass.

Legacy ACP clients continue working without this extension. A remote libfx client
connecting to a legacy server reports unavailable interactive command support and
may offer an explicit native-terminal entry point. It must not synthesize settings
or pretend to provide command parity. Existing local WASM host stores and revision
conflicts remain unchanged by the new remote mode.

## Incremental delivery and acceptance

1. Extract a narrow interaction result contract around the existing model command
   and accepted configuration. Preserve terminal behavior and test it against the
   same core owner. Prove one fx-owned picker in native terminal and HTML before
   expanding the schema.
2. Add capability negotiation and a persistent ACP extension adapter. Provide a
   dependency-free libfx remote controller, optional reference DOM interaction
   renderer, and a small authenticated transport example. Include permissions and
   lifecycle correctness in this first usable slice.
3. Move remaining command presentation seams onto the shared contract, including
   session resume, compaction, MCP, and settings. Publish a capability matrix
   derived from implementation coverage. Do not advertise full parity early.
4. Evaluate a remote libfx terminal renderer independently. Preserve PTY access
   throughout; do not hold HTML support hostage to terminal rendering extraction.

Acceptance scenarios for each supported presentation:

- `/model` opens the fx-owned picker and accepts the same model/configuration
  change as native fx. `/models` follows the connected registry: on the inspected
  main it is rejected as unknown. Neither request becomes model prose.
- `/compact`, `/resume`, `/permissions`, and `/mcp` run through the same core
  behavior when supported, otherwise return an explicit capability reason.
- Two prompts reuse one attached native process; no provisioning call occurs
  between them. A long-running native tool proceeds without browser tool RPC.
- Cancel works during streaming and pending interaction; stale permissions cannot
  approve a new operation. Reconnect neither duplicates a prompt nor loses the
  accepted configuration or session identity.
- A host can render HTML transcript content and mount fx interaction surfaces
  without implementing a command-name switch or a settings registry.
- Legacy ACP and local libfx tests retain their current behavior. Unknown schema
  versions, invalid actions, origin/auth failures, slow consumers, and connection
  loss fail predictably.

Implementation validation should use existing focused command, ACP, SDK, and
terminal suites with a deterministic fake provider and a real persistent transport.
Compare native and remote semantic outcomes, not pixel identity. Measure the
above latency phases before setting a numeric regression budget. No live model or
paid sandbox is required to review this documentation-only proposal.

## Open decisions

- Which existing command output snapshots can be reused directly, and which
  interactive handlers need a typed operation result before they can be shared?
- Should the reference DOM renderer ship inside an optional libfx subpath or as
  a separate package, while preserving a dependency-free core SDK?
- Is remote terminal rendering worth a UI-only WASM build, or does native PTY
  provide the better initial terminal experience?
- What bounded replay window and disconnect policy should the first owner
  service guarantee, and should multi-view ownership transfer wait for a later RFC?
