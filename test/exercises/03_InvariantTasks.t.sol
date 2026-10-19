// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../../src/MockUSDC.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {TBillToken} from "../../src/TBillToken.sol";
import {TBillVault} from "../../src/TBillVault.sol";
import {MockPriceFeed} from "../../src/exercises/MockPriceFeed.sol";
import {MockTBillCustodian} from "../../src/exercises/MockTBillCustodian.sol";
import {RedemptionQueue} from "../../src/exercises/RedemptionQueue.sol";

/// @title Ex6 — the two bridge invariants
/// @notice Invariant testing flips the usual test around: let the machine call operations
///         randomly and repeatedly, then ask "no matter how it thrashes, does this property
///         still hold?" That is how a bridge should be tested — you will never guess the order
///         an attacker does things in.
///
///         Acceptance: make exercise.
///
/// @dev Ex6 depends on Ex5: the handler below calls enqueue / settle / claim in
///      RedemptionQueue.sol.
///
///      How it works: Foundry picks a function from the handler at random, picks random
///      arguments, calls it, and repeats N times; after each round it runs every invariant_*
///      function. The first failed assertion is a counterexample.
contract BridgeHandler is Test {
    MockUSDC internal usdc;
    TBillToken internal tBill;
    TBillVault internal vault;
    RedemptionQueue internal queue;

    address[3] public users;

    /// @dev Bookkeeping: proves the fuzzer really reached the handler instead of idling
    uint256 public ghost_enqueues;
    uint256 public ghost_settles;
    uint256 public ghost_claims;

    constructor(MockUSDC usdc_, TBillToken tBill_, TBillVault vault_, RedemptionQueue queue_) {
        usdc = usdc_;
        tBill = tBill_;
        vault = vault_;
        queue = queue_;

        users[0] = makeAddr("user0");
        users[1] = makeAddr("user1");
        users[2] = makeAddr("user2");
        for (uint256 i; i < users.length; ++i) {
            usdc.faucet(users[i], 100_000e6);
        }
    }

    /// @dev Given — pay USDC, receive shares at today's NAV
    function subscribe(uint256 userSeed, uint256 amount) external {
        address user = users[bound(userSeed, 0, users.length - 1)];

        uint256 balance = usdc.balanceOf(user);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.subscribe(amount);
        vm.stopPrank();
    }

    /// @dev Given — the reporter moves the NAV. Kept inside a sane band so the fuzzer spends
    ///      its budget on the queue rather than on absurd prices.
    function attest(uint256 navSeed) external {
        vault.attest(int256(bound(navSeed, 0.5e8, 2e8)));
    }

    /// @dev Given — the SPV wires cash back into the vault, the way T+1 proceeds would arrive
    function fundVault(uint256 amount) external {
        uint256 balance = usdc.balanceOf(address(this));
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        usdc.approve(address(vault), amount);
        vault.depositReserves(amount);
    }

    /// Ex6.1 — enqueue shares for a user who holds them, after approving the queue.
    function enqueue(uint256 userSeed, uint256 amount) external {
        address user = users[bound(userSeed, 0, users.length - 1)];

        uint256 balance = tBill.balanceOf(user);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        vm.startPrank(user);
        tBill.approve(address(queue), amount);
        queue.enqueue(amount);
        vm.stopPrank();

        ghost_enqueues += 1;
    }

    /// Ex6.2 — settle using available reserves; insufficient cash leaves the head waiting.
    function settle(uint256 assets) external {
        uint256 reserves = vault.reserveBalance();
        if (reserves == 0) return;
        assets = bound(assets, 1, reserves);

        queue.settle(assets);

        ghost_settles += 1;
    }

    /// Ex6.3 — claim as a user with settled cash.
    function claim(uint256 userSeed) external {
        address user = users[bound(userSeed, 0, users.length - 1)];

        if (queue.claimable(user) == 0) return;

        vm.startPrank(user);
        queue.claim();
        vm.stopPrank();

        ghost_claims += 1;
    }
}

contract InvariantTasksTest is Test {
    MockUSDC internal usdc;
    ComplianceRegistry internal compliance;
    TBillToken internal tBill;
    MockTBillCustodian internal custodian;
    TBillVault internal vault;
    RedemptionQueue internal queue;
    BridgeHandler internal handler;

    address internal admin = address(this);

    function setUp() public {
        usdc = new MockUSDC();
        compliance = new ComplianceRegistry(admin);
        MockPriceFeed feed = new MockPriceFeed(1e8);
        tBill = new TBillToken(admin, compliance);
        custodian = new MockTBillCustodian(admin);
        vault = new TBillVault(usdc, tBill, feed, custodian, admin);
        queue = new RedemptionQueue(vault, tBill, usdc, admin);

        tBill.grantRole(tBill.MINTER_ROLE(), address(vault));
        tBill.grantRole(tBill.MINTER_ROLE(), address(queue));
        custodian.grantRole(custodian.CUSTODIAN_ROLE(), address(vault));
        vault.setQueue(address(queue));

        compliance.setWhitelisted(address(queue), true);

        handler = new BridgeHandler(usdc, tBill, vault, queue);

        for (uint256 i; i < 3; ++i) {
            compliance.setWhitelisted(handler.users(i), true);
        }
        compliance.setWhitelisted(address(handler), true);

        vault.grantRole(vault.REPORTER_ROLE(), address(handler));
        vault.grantRole(vault.OPERATOR_ROLE(), address(handler));
        queue.grantRole(queue.SETTLER_ROLE(), address(handler));

        // Let the fuzzer call only the handler's own actions, not its inherited helpers
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = BridgeHandler.subscribe.selector;
        selectors[1] = BridgeHandler.attest.selector;
        selectors[2] = BridgeHandler.fundVault.selector;
        selectors[3] = BridgeHandler.enqueue.selector;
        selectors[4] = BridgeHandler.settle.selector;
        selectors[5] = BridgeHandler.claim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// Ex6.4 — escrow conservation (plank c)
    /// @dev The queue holds exactly the shares it still owes a payout for.
    function invariant_EscrowConservation() public view {
        assertEq(
            tBill.balanceOf(address(queue)),
            queue.pendingShares(),
            "the queue holds exactly the shares it still owes a payout for"
        );
    }

    /// Ex6.5 — settlement solvency (plank c)
    /// @dev The queue never owes settled cash it does not hold: it pays at least what the
    ///      claimable balances add up to.
    ///
    ///      Then ask yourself why nobody can write the more tempting invariant:
    ///        vault.reserveBalance() >= queue.pendingAssets()
    ///      Hint: when the NAV rises, where does the extra value physically sit? Is it in the
    ///      vault's USDC buffer, or in the T-Bills at the custodian? That gap is the whole
    ///      lesson of this lab — write your answer up as question C1.
    function invariant_SettlementSolvency() public view {
        assertGe(
            usdc.balanceOf(address(queue)),
            queue.totalClaimable(),
            "the queue never owes settled cash it does not hold"
        );
    }
}
