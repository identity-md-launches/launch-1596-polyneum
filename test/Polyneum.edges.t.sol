// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Polyneum} from "../src/Polyneum.sol";

/// @notice Adversarial edge cases and algebraic properties for Polyneum, beside the behavioural
///         suite in Polyneum.t.sol. Inputs the author may not have considered: zero where a check
///         expects more, the unlimited-allowance sentinel and its neighbour, the owner spending
///         through transferFrom, the same call twice, raw calldata from a stranger, and the
///         commutativity / additivity / round-trip shape of transfers.
/// forge-config: default.fuzz.runs = 1000
contract PolyneumEdgesTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 constant MAX = type(uint256).max;

    address constant DEPLOYER = address(0xFAC7);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA201);

    Polyneum token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new Polyneum();
    }

    // ---------------------------------------------------------------------------------------------
    // Pinned boundaries: zero, one wei, the full supply, the maximum
    // ---------------------------------------------------------------------------------------------

    function test_transferOneWei() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 1);
        assertEq(token.balanceOf(ALICE), 1);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - 1);
    }

    function test_transferOneWeiMoreThanBalanceReverts() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(Polyneum.InsufficientBalance.selector, DEPLOYER, SUPPLY, SUPPLY + 1));
        token.transfer(ALICE, SUPPLY + 1);
    }

    function test_transferMaxUintReverts() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(Polyneum.InsufficientBalance.selector, DEPLOYER, SUPPLY, MAX));
        token.transfer(ALICE, MAX);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
    }

    /// @dev The receiver check comes first: even a zero-amount transfer to the zero address reverts.
    function test_transferZeroAmountToZeroAddressStillReverts() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(Polyneum.InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
    }

    /// @dev EIP-20: a zero-value transfer MUST fire the Transfer event.
    function test_transferZeroAmountEmitsEvent() public {
        vm.prank(BOB); // BOB holds nothing; zero still succeeds and still emits.
        vm.expectEmit(true, true, true, true);
        emit Transfer(BOB, ALICE, 0);
        token.transfer(ALICE, 0);
    }

    function test_transferZeroAmountToSelfFromEmptyAccount() public {
        vm.prank(BOB);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_sameTransferTwiceFailsOnceDrained() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 10);

        vm.prank(ALICE);
        token.transfer(BOB, 10);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Polyneum.InsufficientBalance.selector, ALICE, 0, 10));
        token.transfer(BOB, 10);

        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 10);
    }

    function test_failedTransferLeavesNoTrace() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 5);

        vm.recordLogs();
        vm.prank(ALICE);
        (bool ok,) = address(token).call(abi.encodeCall(token.transfer, (BOB, 6)));
        assertFalse(ok);
        assertEq(vm.getRecordedLogs().length, 0, "a failed transfer emitted something");
        assertEq(token.balanceOf(ALICE), 5);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // approve edges
    // ---------------------------------------------------------------------------------------------

    function test_approveZeroAmountSucceedsAndEmits() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 5);
        vm.prank(DEPLOYER);
        vm.expectEmit(true, true, true, true);
        emit Approval(DEPLOYER, ALICE, 0);
        assertTrue(token.approve(ALICE, 0));
        assertEq(token.allowance(DEPLOYER, ALICE), 0);
    }

    function test_approveZeroSpenderWithZeroAmountStillReverts() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(Polyneum.InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
    }

    function test_approveIsIndependentOfBalance() public {
        // An account with nothing may approve anything; the allowance is a cap, not a reservation.
        vm.prank(BOB);
        assertTrue(token.approve(ALICE, MAX));
        assertEq(token.allowance(BOB, ALICE), MAX);
        // ...but spending it still needs a balance.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Polyneum.InsufficientBalance.selector, BOB, 0, 1));
        token.transferFrom(BOB, CAROL, 1);
    }

    function test_approveSelfThenSpendOwnTokensViaTransferFrom() public {
        vm.startPrank(DEPLOYER);
        token.approve(DEPLOYER, 3);
        token.transferFrom(DEPLOYER, ALICE, 3);
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), 3);
        assertEq(token.allowance(DEPLOYER, DEPLOYER), 0);
    }

    /// @dev There is no implicit self-allowance: the owner calling transferFrom on itself without
    ///      an approval fails exactly like any other spender.
    function test_ownerHasNoImplicitAllowanceForTransferFrom() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(Polyneum.InsufficientAllowance.selector, DEPLOYER, 0, 1));
        token.transferFrom(DEPLOYER, ALICE, 1);
    }

    // ---------------------------------------------------------------------------------------------
    // transferFrom edges and the unlimited sentinel
    // ---------------------------------------------------------------------------------------------

    function test_transferFromZeroAmountWithoutAllowanceSucceeds() public {
        vm.prank(ALICE);
        vm.expectEmit(true, true, true, true);
        emit Transfer(DEPLOYER, BOB, 0);
        assertTrue(token.transferFrom(DEPLOYER, BOB, 0));
        assertEq(token.allowance(DEPLOYER, ALICE), 0);
    }

    function test_transferFromExactAllowanceThenOneWeiMoreReverts() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 10);

        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, 10);
        assertEq(token.allowance(DEPLOYER, ALICE), 0);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Polyneum.InsufficientAllowance.selector, ALICE, 0, 1));
        token.transferFrom(DEPLOYER, BOB, 1);
    }

    /// @dev Only exactly type(uint256).max is unlimited; one below it is an ordinary allowance.
    function test_allowanceMaxMinusOneIsDecreased() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, MAX - 1);
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, 7);
        assertEq(token.allowance(DEPLOYER, ALICE), MAX - 1 - 7);
    }

    function test_unlimitedAllowanceSurvivesSpendingTheWholeBalance() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, MAX);
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, SUPPLY);
        assertEq(token.allowance(DEPLOYER, ALICE), MAX);
        assertEq(token.balanceOf(DEPLOYER), 0);
        assertEq(token.balanceOf(BOB), SUPPLY);
        // Unlimited allowance still cannot conjure tokens.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Polyneum.InsufficientBalance.selector, DEPLOYER, 0, 1));
        token.transferFrom(DEPLOYER, BOB, 1);
    }

    function test_transferFromSelfToSelfKeepsBalanceButSpendsAllowance() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 10);
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, DEPLOYER, 4);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.allowance(DEPLOYER, ALICE), 6);
    }

    /// @dev Error precedence: the allowance is checked before the receiver, the receiver before
    ///      the balance. Pinned so a reordering is visible.
    function test_transferFromErrorPrecedence() public {
        // No allowance, zero receiver: allowance wins.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Polyneum.InsufficientAllowance.selector, ALICE, 0, 1));
        token.transferFrom(DEPLOYER, address(0), 1);

        // Allowance ok, zero receiver, insufficient balance: receiver wins.
        vm.prank(BOB);
        token.approve(ALICE, 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Polyneum.InvalidReceiver.selector, address(0)));
        token.transferFrom(BOB, address(0), 1);
    }

    function test_revokedAllowanceCannotBeUsed() public {
        vm.startPrank(DEPLOYER);
        token.approve(ALICE, 10);
        token.approve(ALICE, 0);
        vm.stopPrank();
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Polyneum.InsufficientAllowance.selector, ALICE, 0, 1));
        token.transferFrom(DEPLOYER, BOB, 1);
    }

    function test_allowanceIsDirectional() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 10);
        // ALICE approving nothing back: DEPLOYER cannot spend ALICE's tokens.
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 5);
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(Polyneum.InsufficientAllowance.selector, DEPLOYER, 0, 1));
        token.transferFrom(ALICE, DEPLOYER, 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Raw ABI surface
    // ---------------------------------------------------------------------------------------------

    function test_emptyCalldataReverts() public {
        (bool ok,) = address(token).call("");
        assertFalse(ok, "no fallback should exist");
    }

    function test_unknownSelectorReverts() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("doesNotExist()"));
        assertFalse(ok);
    }

    function test_shortCalldataReverts() public {
        bytes memory data = abi.encodeCall(token.transfer, (ALICE, 1));
        bytes memory truncated = new bytes(data.length - 1);
        for (uint256 i; i < truncated.length; ++i) {
            truncated[i] = data[i];
        }
        vm.prank(DEPLOYER);
        (bool ok,) = address(token).call(truncated);
        assertFalse(ok);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function test_viewFunctionsAnswerForAnyCaller() public view {
        bytes4[6] memory views = [
            bytes4(keccak256("name()")),
            bytes4(keccak256("symbol()")),
            bytes4(keccak256("decimals()")),
            bytes4(keccak256("totalSupply()")),
            bytes4(keccak256("balanceOf(address)")),
            bytes4(keccak256("allowance(address,address)"))
        ];
        for (uint256 i; i < views.length; ++i) {
            (bool ok, bytes memory ret) =
                address(token).staticcall(abi.encodeWithSelector(views[i], address(0xBEEF), address(0xCAFE)));
            assertTrue(ok);
            assertGt(ret.length, 0);
        }
    }

    function test_valueBearingCallToTransferReverts() public {
        vm.deal(DEPLOYER, 1 ether);
        vm.prank(DEPLOYER);
        (bool ok,) = address(token).call{value: 1}(abi.encodeCall(token.transfer, (ALICE, 1)));
        assertFalse(ok, "non-payable transfer accepted ether");
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(address(token).balance, 0);
    }

    /// @dev Any calldata from any caller who is not the holder and holds no allowance leaves the
    ///      holder's balance and the supply exactly where they were. This is the "no privileged
    ///      hand" property over the whole ABI, not just a list of guessed admin selectors.
    function testFuzz_arbitraryCallFromStrangerNeverMovesAHolder(address caller, bytes calldata data) public {
        // A stranger: not a holder and never approved. Remapped rather than assumed so no run is discarded.
        if (caller == DEPLOYER || caller == ALICE) caller = CAROL;

        vm.prank(DEPLOYER);
        token.transfer(ALICE, 1_000e18);
        uint256 heldAlice = token.balanceOf(ALICE);
        uint256 heldDeployer = token.balanceOf(DEPLOYER);

        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        ok; // success or failure, the holders are untouched

        assertEq(token.balanceOf(ALICE), heldAlice);
        assertEq(token.balanceOf(DEPLOYER), heldDeployer);
        assertEq(token.balanceOf(caller), 0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.allowance(ALICE, caller), 0);
        assertEq(token.allowance(DEPLOYER, caller), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Algebraic properties
    // ---------------------------------------------------------------------------------------------

    /// @dev Round trip: send then send back returns both parties to where they started.
    function testFuzz_transferRoundTrip(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, amount);
        vm.prank(ALICE);
        token.transfer(DEPLOYER, amount);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }

    /// @dev Additivity: two transfers of a and b leave the same state as one transfer of a + b.
    function testFuzz_splitTransferEqualsSingleTransfer(uint256 a, uint256 b) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, SUPPLY - a);

        uint256 snap = vm.snapshotState();
        vm.prank(DEPLOYER);
        token.transfer(ALICE, a);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, b);
        uint256 splitAlice = token.balanceOf(ALICE);
        uint256 splitDeployer = token.balanceOf(DEPLOYER);
        vm.revertToState(snap);

        vm.prank(DEPLOYER);
        token.transfer(ALICE, a + b);
        assertEq(token.balanceOf(ALICE), splitAlice);
        assertEq(token.balanceOf(DEPLOYER), splitDeployer);
    }

    /// @dev Order independence: transfers to two different receivers commute.
    function testFuzz_transfersToDistinctReceiversCommute(uint256 a, uint256 b) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, SUPPLY - a);

        uint256 snap = vm.snapshotState();
        vm.prank(DEPLOYER);
        token.transfer(ALICE, a);
        vm.prank(DEPLOYER);
        token.transfer(BOB, b);
        uint256 alice1 = token.balanceOf(ALICE);
        uint256 bob1 = token.balanceOf(BOB);
        uint256 dep1 = token.balanceOf(DEPLOYER);
        vm.revertToState(snap);

        vm.prank(DEPLOYER);
        token.transfer(BOB, b);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, a);
        assertEq(token.balanceOf(ALICE), alice1);
        assertEq(token.balanceOf(BOB), bob1);
        assertEq(token.balanceOf(DEPLOYER), dep1);
    }

    /// @dev transfer and transferFrom with a sufficient allowance are observationally the same move.
    function testFuzz_transferFromEquivalentToTransfer(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);

        uint256 snap = vm.snapshotState();
        vm.prank(DEPLOYER);
        token.transfer(BOB, amount);
        uint256 bobDirect = token.balanceOf(BOB);
        uint256 depDirect = token.balanceOf(DEPLOYER);
        vm.revertToState(snap);

        vm.prank(DEPLOYER);
        token.approve(ALICE, amount);
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, amount);
        assertEq(token.balanceOf(BOB), bobDirect);
        assertEq(token.balanceOf(DEPLOYER), depDirect);
        assertEq(token.allowance(DEPLOYER, ALICE), 0);
    }

    /// @dev Idempotence of approve: setting the same allowance twice is the same as once, and the
    ///      last write wins regardless of the earlier value.
    function testFuzz_approveLastWriteWins(uint256 first, uint256 second, address spender) public {
        spender = address(uint160(bound(uint256(uint160(spender)), 1, type(uint160).max)));
        vm.startPrank(DEPLOYER);
        token.approve(spender, first);
        token.approve(spender, second);
        token.approve(spender, second);
        vm.stopPrank();
        assertEq(token.allowance(DEPLOYER, spender), second);
    }

    /// @dev Failure path over the whole domain: any amount above a finite allowance reverts with
    ///      exactly that allowance and amount, and nothing moves.
    function testFuzz_transferFromAboveFiniteAllowanceReverts(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, MAX - 1);
        amount = bound(amount, allowed + 1, MAX);
        vm.prank(DEPLOYER);
        token.approve(ALICE, allowed);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Polyneum.InsufficientAllowance.selector, ALICE, allowed, amount));
        token.transferFrom(DEPLOYER, BOB, amount);
        assertEq(token.allowance(DEPLOYER, ALICE), allowed);
        assertEq(token.balanceOf(BOB), 0);
    }

    /// @dev Failure path: any amount above the balance, from any holder level, reverts with the
    ///      exact balance and amount, and nothing moves.
    function testFuzz_transferAboveBalanceRevertsExactly(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, MAX);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, held);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Polyneum.InsufficientBalance.selector, ALICE, held, amount));
        token.transfer(BOB, amount);
        assertEq(token.balanceOf(ALICE), held);
        assertEq(token.balanceOf(BOB), 0);
    }

    /// @dev A receiver can never be pushed past the supply: no sequence of inbound transfers from
    ///      the single source exceeds what the source had.
    function testFuzz_receiverNeverExceedsSupply(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, SUPPLY);
        c = bound(c, 0, SUPPLY);
        uint256[3] memory amounts = [a, b, c];
        for (uint256 i; i < 3; ++i) {
            vm.prank(DEPLOYER);
            (bool ok,) = address(token).call(abi.encodeCall(token.transfer, (ALICE, amounts[i])));
            ok;
        }
        assertLe(token.balanceOf(ALICE), SUPPLY);
        assertEq(token.balanceOf(ALICE) + token.balanceOf(DEPLOYER), SUPPLY);
    }
}
