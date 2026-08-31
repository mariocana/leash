// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PolicyVault} from "../src/PolicyVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract PolicyVaultTest is Test {
    PolicyVault vault;
    MockERC20 token;

    address owner = address(0xA11CE);
    address agent = address(0xB0B);
    address merchant = address(0xCAFE);
    address stranger = address(0xDEAD);

    uint128 constant PER_TX = 2 ether;
    uint128 constant WINDOW_CAP = 5 ether;
    uint64 constant WINDOW = 1 days;

    function setUp() public {
        vault = new PolicyVault();
        token = new MockERC20();
        token.mint(owner, 1000 ether);

        vm.prank(owner);
        token.approve(address(vault), type(uint256).max);

        vm.prank(owner);
        vault.setPolicy(agent, address(token), PER_TX, WINDOW_CAP, WINDOW, uint64(block.timestamp + 30 days), false);
    }

    function _spend(uint256 amount) internal {
        vm.prank(agent);
        vault.spend(owner, address(token), merchant, amount, bytes32("test"));
    }

    // ------------------------------------------------------------ happy path

    function test_SpendMovesFundsAndNeverTouchesTheVault() public {
        _spend(1 ether);
        assertEq(token.balanceOf(merchant), 1 ether);
        assertEq(token.balanceOf(address(vault)), 0, "vault must never hold a balance");
    }

    function test_StatusReportsRemainingAndReset() public {
        _spend(1 ether);
        (bool active, uint256 remaining, uint64 resetsAt,) = vault.status(owner, agent, address(token));
        assertTrue(active);
        assertEq(remaining, WINDOW_CAP - 1 ether);
        assertEq(resetsAt, uint64(block.timestamp) + WINDOW);
    }

    // ----------------------------------------------------------------- caps

    function test_RevertWhen_PerTxCapExceeded() public {
        vm.expectRevert(
            abi.encodeWithSelector(PolicyVault.PerTxCapExceeded.selector, uint256(PER_TX + 1), PER_TX)
        );
        _spend(PER_TX + 1);
    }

    function test_RevertWhen_WindowCapExceeded() public {
        _spend(2 ether);
        _spend(2 ether);
        // 1 ether left in the window, ask for 2
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyVault.WindowCapExceeded.selector, uint256(2 ether), uint256(1 ether), uint64(block.timestamp) + WINDOW
            )
        );
        _spend(2 ether);
    }

    function test_WindowRollsForwardAfterItsLength() public {
        _spend(2 ether);
        _spend(2 ether);
        _spend(1 ether);
        assertEq(token.balanceOf(merchant), 5 ether);

        vm.warp(block.timestamp + WINDOW);
        _spend(2 ether);
        assertEq(token.balanceOf(merchant), 7 ether);
    }

    function test_PartialWindowDoesNotReset() public {
        _spend(2 ether);
        vm.warp(block.timestamp + WINDOW - 1);
        (, uint256 remaining,,) = vault.status(owner, agent, address(token));
        assertEq(remaining, 3 ether);
    }

    // ------------------------------------------------------------- allowlist

    function test_RevertWhen_RecipientNotAllowlisted() public {
        vm.startPrank(owner);
        vault.setPolicy(agent, address(token), PER_TX, WINDOW_CAP, WINDOW, uint64(block.timestamp + 1 days), true);
        vault.setAllowlist(agent, merchant, true);
        vm.stopPrank();

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(PolicyVault.RecipientNotAllowed.selector, stranger));
        vault.spend(owner, address(token), stranger, 1 ether, bytes32(0));

        _spend(1 ether);
        assertEq(token.balanceOf(merchant), 1 ether);
    }

    // ------------------------------------------------------- expiry & revoke

    function test_RevertWhen_PolicyExpired() public {
        vm.warp(block.timestamp + 31 days);
        vm.expectRevert();
        _spend(1 ether);
    }

    function test_RevokeIsImmediate() public {
        vm.prank(owner);
        vault.revoke(agent, address(token));
        vm.expectRevert(
            abi.encodeWithSelector(PolicyVault.NoActivePolicy.selector, owner, agent, address(token))
        );
        _spend(1 ether);
    }

    function test_ReplacingPolicyResetsTheWindow() public {
        _spend(2 ether);
        vm.prank(owner);
        vault.setPolicy(agent, address(token), PER_TX, WINDOW_CAP, WINDOW, uint64(block.timestamp + 30 days), false);
        (, uint256 remaining,,) = vault.status(owner, agent, address(token));
        assertEq(remaining, WINDOW_CAP);
    }

    // ------------------------------------------------------------ isolation

    function test_RevertWhen_CallerIsNotTheGrantedAgent() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(PolicyVault.NoActivePolicy.selector, owner, stranger, address(token))
        );
        vault.spend(owner, address(token), merchant, 1 ether, bytes32(0));
    }

    function test_PolicyIsScopedPerToken() public {
        MockERC20 other = new MockERC20();
        other.mint(owner, 100 ether);
        vm.prank(owner);
        other.approve(address(vault), type(uint256).max);

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(PolicyVault.NoActivePolicy.selector, owner, agent, address(other))
        );
        vault.spend(owner, address(other), merchant, 1 ether, bytes32(0));
    }

    // ----------------------------------------------------------- ERC-20 edge

    function test_SilentTokenIsAccepted() public {
        token.setSilent(true);
        _spend(1 ether);
        assertEq(token.balanceOf(merchant), 1 ether);
    }

    function test_RevertWhen_TokenReturnsFalse() public {
        token.setFailing(true);
        vm.expectRevert(PolicyVault.TransferFailed.selector);
        _spend(1 ether);
    }

    // ----------------------------------------------------------------- fuzz

    function testFuzz_NeverExceedsWindowCap(uint128[8] calldata amounts) public {
        uint256 moved;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 a = uint256(amounts[i]) % (3 ether);
            if (a == 0) continue;
            vm.prank(agent);
            try vault.spend(owner, address(token), merchant, a, bytes32(0)) {
                moved += a;
            } catch {}
        }
        assertLe(moved, WINDOW_CAP, "window cap must hold across any sequence");
        assertEq(token.balanceOf(merchant), moved);
    }
}
