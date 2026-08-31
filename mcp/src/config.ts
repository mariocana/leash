import { celo } from "viem/chains";

/**
 * Every transaction Leash sends must carry the attribution tag assigned at
 * registration, or it is invisible to every hackathon leaderboard.
 * Set LEASH_ATTRIBUTION_TAG once the celobuilders registration returns it.
 */
export const ATTRIBUTION_TAG = process.env.LEASH_ATTRIBUTION_TAG ?? "";

export const VAULT_ADDRESS = process.env.LEASH_VAULT_ADDRESS as `0x${string}`;
export const OWNER_ADDRESS = process.env.LEASH_OWNER_ADDRESS as `0x${string}`;
export const TOKEN_ADDRESS = process.env.LEASH_TOKEN_ADDRESS as `0x${string}`;

/** cUSD on Celo mainnet — also usable as feeCurrency so the agent needs no CELO. */
export const CUSD = "0x765DE816845861e75A25fCA122bb6898B8B1282a" as const;

export const chain = celo;

export function assertConfigured(): void {
  const missing = ["LEASH_VAULT_ADDRESS", "LEASH_OWNER_ADDRESS", "LEASH_TOKEN_ADDRESS"].filter(
    (k) => !process.env[k],
  );
  if (missing.length) throw new Error(`missing env: ${missing.join(", ")}`);
  if (!ATTRIBUTION_TAG) {
    console.error("[leash] WARNING: LEASH_ATTRIBUTION_TAG is unset; transactions will not be counted.");
  }
}
