// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Polyneum} from "../src/Polyneum.sol";
import {DeployPolyneum} from "../script/DeployPolyneum.s.sol";

/// @notice Behavioural tests for Polyneum: metadata, the one-time mint, transfers, allowances,
///         failure paths, and the absence of any privileged surface.
contract PolyneumTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 10 ** 18;

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
    // Metadata and supply
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Polyneum");
        assertEq(token.symbol(), "POLYNEUM");
        assertEq(token.decimals(), 18);
    }

    function test_supplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_constructorEmitsMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), DEPLOYER, SUPPLY);
        vm.prank(DEPLOYER);
        new Polyneum();
    }

    function test_eachDeploymentMintsToItsOwnDeployer() public {
        vm.prank(ALICE);
        Polyneum other = new Polyneum();
        assertEq(other.balanceOf(ALICE), SUPPLY);
        assertEq(other.balanceOf(DEPLOYER), 0);
        // Independent of the first deployment.
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // transfer
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesExactAmount() public {
        vm.prank(DEPLOYER);
        vm.expectEmit(true, true, true, true);
        emit Transfer(DEPLOYER, ALICE, 1_000e18);
        assertTrue(token.transfer(ALICE, 1_000e18));

        assertEq(token.balanceOf(ALICE), 1_000e18);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - 1_000e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferWholeBalance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, SUPPLY);
        assertEq(token.balanceOf(ALICE), SUPPLY);
        assertEq(token.balanceOf(DEPLOYER), 0);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_transferToSelfIsNoOp() public {
        vm.prank(DEPLOYER);
        token.transfer(DEPLOYER, 5e18);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 10e18);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Polyneum.InsufficientBalance.selector, ALICE, 10e18, 10e18 + 1));
        token.transfer(BOB, 10e18 + 1);
    }

    function test_transferRevertsFromEmptyAccount() public {
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(Polyneum.InsufficientBalance.selector, BOB, 0, 1));
        token.transfer(ALICE, 1);
    }

    function test_transferRevertsToZeroAddress() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(Polyneum.InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // approve / transferFrom
    // ---------------------------------------------------------------------------------------------

    function test_approveSetsAllowanceAndEmits() public {
        vm.prank(DEPLOYER);
        vm.expectEmit(true, true, true, true);
        emit Approval(DEPLOYER, ALICE, 7e18);
        assertTrue(token.approve(ALICE, 7e18));
        assertEq(token.allowance(DEPLOYER, ALICE), 7e18);
    }

    function test_approveOverwritesPreviousAllowance() public {
        vm.startPrank(DEPLOYER);
        token.approve(ALICE, 7e18);
        token.approve(ALICE, 3e18);
        vm.stopPrank();
        assertEq(token.allowance(DEPLOYER, ALICE), 3e18);
    }

    function test_approveRevertsForZeroSpender() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(Polyneum.InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_transferFromSpendsAllowance() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 10e18);

        vm.prank(ALICE);
        vm.expectEmit(true, true, true, true);
        emit Transfer(DEPLOYER, BOB, 4e18);
        assertTrue(token.transferFrom(DEPLOYER, BOB, 4e18));

        assertEq(token.balanceOf(BOB), 4e18);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - 4e18);
        assertEq(token.allowance(DEPLOYER, ALICE), 6e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromUnlimitedAllowanceIsNotDecreased() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, type(uint256).max);

        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, 4e18);

        assertEq(token.allowance(DEPLOYER, ALICE), type(uint256).max);
        assertEq(token.balanceOf(BOB), 4e18);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Polyneum.InsufficientAllowance.selector, ALICE, 0, 1));
        token.transferFrom(DEPLOYER, BOB, 1);
    }

    function test_transferFromRevertsBeyondAllowance() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 10e18);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Polyneum.InsufficientAllowance.selector, ALICE, 10e18, 10e18 + 1));
        token.transferFrom(DEPLOYER, BOB, 10e18 + 1);
    }

    function test_transferFromRevertsBeyondBalanceEvenWithAllowance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 5e18);
        vm.prank(ALICE);
        token.approve(BOB, 100e18);

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(Polyneum.InsufficientBalance.selector, ALICE, 5e18, 6e18));
        token.transferFrom(ALICE, CAROL, 6e18);
        // Allowance is untouched when the transfer reverts.
        assertEq(token.allowance(ALICE, BOB), 100e18);
    }

    function test_transferFromRevertsToZeroAddress() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Polyneum.InvalidReceiver.selector, address(0)));
        token.transferFrom(DEPLOYER, address(0), 1);
    }

    function test_allowanceIsPerSpender() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 10e18);
        assertEq(token.allowance(DEPLOYER, BOB), 0);

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(Polyneum.InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(DEPLOYER, BOB, 1);
    }

    // ---------------------------------------------------------------------------------------------
    // No privileged surface
    // ---------------------------------------------------------------------------------------------

    function test_noMintOrAdminFunctionExists() public {
        string[14] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "setMinter(address)",
            "upgradeTo(address)",
            "initialize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], address(0xBEEF), type(uint128).max);
            vm.prank(DEPLOYER);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.balanceOf(address(0xBEEF)), 0);
    }

    function test_deployerCannotMoveAHoldersBalance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 1e18);

        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(Polyneum.InsufficientAllowance.selector, DEPLOYER, 0, 1e18));
        token.transferFrom(ALICE, DEPLOYER, 1e18);
        assertEq(token.balanceOf(ALICE), 1e18);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    function test_runtimeFitsEip170() public view {
        assertLe(address(token).code.length, 24_576);
    }

    function test_contractRejectsEther() public {
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Deploy script
    // ---------------------------------------------------------------------------------------------

    function test_deployScriptMintsToCaller() public {
        DeployPolyneum deployer = new DeployPolyneum();
        Polyneum deployed = deployer.deploy();
        // The script contract is msg.sender of the creation, so it holds the supply.
        assertEq(deployed.balanceOf(address(deployer)), SUPPLY);
        assertEq(deployed.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz and invariants
    // ---------------------------------------------------------------------------------------------

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, SUPPLY);

        vm.prank(DEPLOYER);
        token.transfer(to, amount);

        if (to == DEPLOYER) {
            assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        } else {
            assertEq(token.balanceOf(to), amount);
            assertEq(token.balanceOf(DEPLOYER), SUPPLY - amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 amount) public {
        amount = bound(amount, SUPPLY + 1, type(uint256).max);
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(Polyneum.InsufficientBalance.selector, DEPLOYER, SUPPLY, amount));
        token.transfer(ALICE, amount);
    }

    function testFuzz_transferFromWithinAllowance(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, SUPPLY);
        amount = bound(amount, 0, allowed);

        vm.prank(DEPLOYER);
        token.approve(ALICE, allowed);
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, amount);

        assertEq(token.balanceOf(BOB), amount);
        assertEq(token.allowance(DEPLOYER, ALICE), allowed - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_chainOfTransfersConservesSupply(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, a);
        c = bound(c, 0, b);

        vm.prank(DEPLOYER);
        token.transfer(ALICE, a);
        vm.prank(ALICE);
        token.transfer(BOB, b);
        vm.prank(BOB);
        token.transfer(CAROL, c);

        uint256 sum = token.balanceOf(DEPLOYER) + token.balanceOf(ALICE) + token.balanceOf(BOB) + token.balanceOf(CAROL);
        assertEq(sum, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
