// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title  PolicyVault
/// @notice On-chain spending guardrails for autonomous agents.
/// @dev    The owner keeps custody: funds sit in the owner's own wallet and are
///         pulled with `transferFrom` only when a spend passes the policy. The
///         vault never holds a balance, so there is nothing here to drain.
///
///         An owner grants an agent a per-(agent, token) policy with a per-tx
///         cap, a rolling-window cap, an expiry, and an optional recipient
///         allowlist. Revocation is immediate.
contract PolicyVault {
    struct Policy {
        uint128 perTxCap;       // max value of a single spend
        uint128 windowCap;      // max value across one rolling window
        uint128 spentInWindow;  // consumed so far in the current window
        uint64 windowStart;     // unix ts the current window opened
        uint64 windowLength;    // window duration in seconds
        uint64 expiry;          // unix ts after which the policy is dead
        bool allowlistOnly;     // restrict recipients to the allowlist
        bool active;            // false once revoked or never set
    }

    /// @dev owner => agent => token => policy
    mapping(address => mapping(address => mapping(address => Policy))) private _policies;

    /// @dev owner => agent => recipient => allowed
    mapping(address => mapping(address => mapping(address => bool))) private _allowlist;

    event PolicySet(
        address indexed owner,
        address indexed agent,
        address indexed token,
        uint128 perTxCap,
        uint128 windowCap,
        uint64 windowLength,
        uint64 expiry,
        bool allowlistOnly
    );
    event PolicyRevoked(address indexed owner, address indexed agent, address indexed token);
    event AllowlistSet(address indexed owner, address indexed agent, address indexed recipient, bool allowed);
    event Spent(
        address indexed owner,
        address indexed agent,
        address indexed token,
        address recipient,
        uint256 amount,
        uint128 spentInWindow,
        uint64 windowResetsAt,
        bytes32 memo
    );

    error NoActivePolicy(address owner, address agent, address token);
    error PolicyExpired(uint64 expiry, uint64 blockTimestamp);
    error PerTxCapExceeded(uint256 requested, uint128 perTxCap);
    error WindowCapExceeded(uint256 requested, uint256 remaining, uint64 windowResetsAt);
    error RecipientNotAllowed(address recipient);
    error ZeroAmount();
    error ZeroAddress();
    error AmountTooLarge();
    error TransferFailed();

    // ---------------------------------------------------------------- owner

    /// @notice Create or replace the policy this caller grants `agent` for `token`.
    /// @dev    Replacing a policy resets the spent-in-window counter.
    function setPolicy(
        address agent,
        address token,
        uint128 perTxCap,
        uint128 windowCap,
        uint64 windowLength,
        uint64 expiry,
        bool allowlistOnly
    ) external {
        if (agent == address(0) || token == address(0)) revert ZeroAddress();
        if (perTxCap == 0 || windowCap == 0 || windowLength == 0) revert ZeroAmount();
        if (expiry <= block.timestamp) revert PolicyExpired(expiry, uint64(block.timestamp));

        _policies[msg.sender][agent][token] = Policy({
            perTxCap: perTxCap,
            windowCap: windowCap,
            spentInWindow: 0,
            windowStart: uint64(block.timestamp),
            windowLength: windowLength,
            expiry: expiry,
            allowlistOnly: allowlistOnly,
            active: true
        });

        emit PolicySet(msg.sender, agent, token, perTxCap, windowCap, windowLength, expiry, allowlistOnly);
    }

    /// @notice Kill a policy immediately. Safe to call on a policy that never existed.
    function revoke(address agent, address token) external {
        delete _policies[msg.sender][agent][token];
        emit PolicyRevoked(msg.sender, agent, token);
    }

    /// @notice Allow or disallow a recipient for one of this caller's agents.
    function setAllowlist(address agent, address recipient, bool allowed) external {
        _allowlist[msg.sender][agent][recipient] = allowed;
        emit AllowlistSet(msg.sender, agent, recipient, allowed);
    }

    /// @notice Batch form of `setAllowlist`.
    function setAllowlistBatch(address agent, address[] calldata recipients, bool allowed) external {
        for (uint256 i; i < recipients.length; ++i) {
            _allowlist[msg.sender][agent][recipients[i]] = allowed;
            emit AllowlistSet(msg.sender, agent, recipients[i], allowed);
        }
    }

    // ---------------------------------------------------------------- agent

    /// @notice Spend `amount` of `owner`'s `token` to `recipient` under the caller's policy.
    /// @param  memo Free-form tag echoed in the `Spent` event, for the agent's own bookkeeping.
    function spend(address owner, address token, address recipient, uint256 amount, bytes32 memo) external {
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount > type(uint128).max) revert AmountTooLarge();

        Policy storage p = _policies[owner][msg.sender][token];
        if (!p.active) revert NoActivePolicy(owner, msg.sender, token);
        if (block.timestamp >= p.expiry) revert PolicyExpired(p.expiry, uint64(block.timestamp));
        if (amount > p.perTxCap) revert PerTxCapExceeded(amount, p.perTxCap);
        if (p.allowlistOnly && !_allowlist[owner][msg.sender][recipient]) revert RecipientNotAllowed(recipient);

        // Lazily roll the window forward before accounting.
        uint64 windowStart = p.windowStart;
        uint128 spent = p.spentInWindow;
        if (block.timestamp >= windowStart + p.windowLength) {
            windowStart = uint64(block.timestamp);
            spent = 0;
            p.windowStart = windowStart;
        }

        uint256 remaining = p.windowCap > spent ? p.windowCap - spent : 0;
        if (amount > remaining) {
            revert WindowCapExceeded(amount, remaining, windowStart + p.windowLength);
        }

        // Effects before interaction.
        uint128 newSpent = spent + uint128(amount);
        p.spentInWindow = newSpent;

        emit Spent(owner, msg.sender, token, recipient, amount, newSpent, windowStart + p.windowLength, memo);

        _safeTransferFrom(token, owner, recipient, amount);
    }

    // ----------------------------------------------------------------- view

    function getPolicy(address owner, address agent, address token) external view returns (Policy memory) {
        return _policies[owner][agent][token];
    }

    /// @notice What the agent can still spend right now, and when the window rolls.
    /// @dev    Accounts for an elapsed window without needing a transaction first.
    function status(address owner, address agent, address token)
        external
        view
        returns (bool active, uint256 remainingInWindow, uint64 windowResetsAt, uint64 expiry)
    {
        Policy storage p = _policies[owner][agent][token];
        if (!p.active || block.timestamp >= p.expiry) {
            return (false, 0, 0, p.expiry);
        }
        if (block.timestamp >= p.windowStart + p.windowLength) {
            return (true, p.windowCap, uint64(block.timestamp) + p.windowLength, p.expiry);
        }
        uint256 rem = p.windowCap > p.spentInWindow ? p.windowCap - p.spentInWindow : 0;
        return (true, rem, p.windowStart + p.windowLength, p.expiry);
    }

    function isAllowed(address owner, address agent, address recipient) external view returns (bool) {
        return _allowlist[owner][agent][recipient];
    }

    // -------------------------------------------------------------- internal

    /// @dev Handles both reverting and `false`-returning ERC-20s, and tokens
    ///      that return no data at all (several are live on Celo).
    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(0x23b872dd, from, to, amount)); // transferFrom
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
