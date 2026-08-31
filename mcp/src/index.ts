/**
 * Leash MCP server — round 1.
 *
 * Three tools: spend, policy_status, request_increase.
 * Deliberately thin: the AskBots baseline review should see the real surface,
 * not a polished one. Error ergonomics and setup flow land in round 2.
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { createPublicClient, createWalletClient, http, parseUnits, formatUnits, stringToHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { toDataSuffix } from "@celo/attribution-tags";
import { ATTRIBUTION_TAG, VAULT_ADDRESS, OWNER_ADDRESS, TOKEN_ADDRESS, chain, assertConfigured } from "./config.js";

const VAULT_ABI = [
  {
    type: "function",
    name: "spend",
    stateMutability: "nonpayable",
    inputs: [
      { name: "owner", type: "address" },
      { name: "token", type: "address" },
      { name: "recipient", type: "address" },
      { name: "amount", type: "uint256" },
      { name: "memo", type: "bytes32" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "status",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "agent", type: "address" },
      { name: "token", type: "address" },
    ],
    outputs: [
      { name: "active", type: "bool" },
      { name: "remainingInWindow", type: "uint256" },
      { name: "windowResetsAt", type: "uint64" },
      { name: "expiry", type: "uint64" },
    ],
  },
] as const;

assertConfigured();

const account = privateKeyToAccount(process.env.LEASH_AGENT_KEY as `0x${string}`);
const transport = http(process.env.CELO_RPC_URL ?? "https://forno.celo.org");
const publicClient = createPublicClient({ chain, transport });
const walletClient = createWalletClient({ account, chain, transport });

const server = new McpServer({ name: "leash", version: "0.1.0" });

server.tool(
  "policy_status",
  "How much this agent may still spend, and when the window resets.",
  {},
  async () => {
    const [active, remaining, resetsAt, expiry] = await publicClient.readContract({
      address: VAULT_ADDRESS,
      abi: VAULT_ABI,
      functionName: "status",
      args: [OWNER_ADDRESS, account.address, TOKEN_ADDRESS],
    });
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify({
            active,
            remaining: formatUnits(remaining, 18),
            windowResetsAt: Number(resetsAt),
            expiry: Number(expiry),
          }),
        },
      ],
    };
  },
);

server.tool(
  "spend",
  "Pay a recipient from the owner's wallet, within the on-chain policy.",
  { to: z.string(), amount: z.string(), memo: z.string().max(31).optional() },
  async ({ to, amount, memo }) => {
    // TODO(round 2): translate contract custom errors into structured,
    // LLM-actionable JSON instead of letting the raw revert bubble up.
    const hash = await walletClient.writeContract({
      address: VAULT_ADDRESS,
      abi: VAULT_ABI,
      functionName: "spend",
      args: [OWNER_ADDRESS, TOKEN_ADDRESS, to as `0x${string}`, parseUnits(amount, 18), stringToHex(memo ?? "", { size: 32 })],
      dataSuffix: toDataSuffix(ATTRIBUTION_TAG),
    });
    return { content: [{ type: "text", text: JSON.stringify({ hash }) }] };
  },
);

server.tool(
  "request_increase",
  "Ask the human owner to raise a cap. Returns the call they need to sign.",
  { newWindowCap: z.string(), reason: z.string() },
  async ({ newWindowCap, reason }) => {
    // TODO(round 2): deliver this out-of-band instead of returning a string.
    return {
      content: [
        { type: "text", text: JSON.stringify({ action: "setPolicy", windowCap: newWindowCap, reason }) },
      ],
    };
  },
);

await server.connect(new StdioServerTransport());
