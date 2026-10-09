// The MCP and skills adapters, as the README combines them with an agent.
import { createFxAgent } from "libfx";
import { createMcpAdapter, type McpAdapter, type McpClient } from "libfx/mcp";
import { createSkillsAdapter, type SkillRecord } from "libfx/skills";
import { createSkillsAdapter as createSkillsAdapterFromNode, loadSkillFile, type LoadedSkill } from "libfx/skills/node";

type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends (<T>() => T extends B ? 1 : 2) ? true : false;
function assertType<T extends true>(): void {}

declare const apiKey: string;
declare const model: string;

// Shaped like the MCP TypeScript SDK v1 `Client`.
const client = {
  async listTools(params?: { cursor?: string }) {
    return { tools: [{ name: "search_issues", description: "Search issues.", inputSchema: { type: "object" as const, properties: {} } }], nextCursor: params?.cursor };
  },
  async callTool(params: { name: string; arguments?: Record<string, unknown> }, resultSchema?: object, options?: { signal?: AbortSignal; timeout?: number }) {
    return { content: [{ type: "text", text: `${params.name} ${String(resultSchema)} ${String(options?.timeout)}` }], isError: false };
  },
  async readResource(params: { uri: string }) {
    return { contents: [{ uri: params.uri, text: "Use the issue template." }] };
  },
  async getPrompt(params: { name: string; arguments?: Record<string, string> }) {
    return { messages: [{ role: "user", content: { type: "text", text: params.name } }] };
  },
  async close() {},
};

export async function mcp(): Promise<void> {
  const adapter = await createMcpAdapter(client, {
    prefix: "github_",
    resources: ["repo://instructions"],
    prompts: ["review", { name: "triage", arguments: { label: "bug" } }],
  });
  assertType<Equal<typeof adapter, McpAdapter>>();

  const agent = createFxAgent({
    apiKey,
    model,
    tools: adapter.tools,
    instructions: adapter.instructions,
  });

  await agent.close();
  await adapter.close();

  const minimal: McpClient = { listTools: async () => [], callTool: async () => ({ content: [] }) };
  await createMcpAdapter(minimal);
  // @ts-expect-error an MCP client needs callTool()
  await createMcpAdapter({ listTools: async () => [] });
}

export async function skills(): Promise<void> {
  const record = await loadSkillFile("./skills/review/SKILL.md");
  assertType<Equal<typeof record, LoadedSkill>>();
  assertType<Equal<typeof record.description, string>>();
  const skills = createSkillsAdapter([record]);
  const agent = createFxAgent({ apiKey, model, ...skills });
  await agent.close();

  const records: SkillRecord[] = [
    { name: "release", instructions: "Write release notes.", description: "Release notes", resources: [{ uri: "doc://style", text: "Be brief." }] },
  ];
  createSkillsAdapterFromNode(records);
  await loadSkillFile("./SKILL.md", { readFile: async () => "---\nname: x\n---\nBody", resources: [], tools: [] });

  // @ts-expect-error a skill record needs instructions
  createSkillsAdapter([{ name: "review" }]);
}
