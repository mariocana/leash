# Leash

On-chain spending guardrails for autonomous agents on Celo.

You would not hand an agent your card. Leash lets you hand it a capped,
revocable, expiring allowance instead, enforced by a contract rather than by a
prompt.

The owner approves the vault on an ERC-20 and sets a policy for one agent
address: a per-transaction cap, a rolling-window cap, an expiry, and an
optional recipient allowlist. The agent calls `spend`. Funds move straight from
the owner's wallet to the recipient — **the vault never holds a balance**, so
there is nothing in it to drain.

## Status

Early. The contract and its tests are done; the MCP server is a thin first cut.

## Layout

    src/PolicyVault.sol   the contract
    test/                 forge tests, including a fuzz run on the window cap
    mcp/                  MCP server exposing spend / policy_status / request_increase

## Build

    forge install foundry-rs/forge-std
    forge test

## Notes

Celo mainnet. Gas is payable in cUSD via `feeCurrency`, so the agent never
needs to hold CELO.

Built for the Celo Agents at Work hackathon.
