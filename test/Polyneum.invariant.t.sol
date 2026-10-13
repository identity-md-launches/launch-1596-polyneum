// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Polyneum} from "../src/Polyneum.sol";

/// @notice Random sequences of transfers, approvals and transferFroms between a fixed set of actors.
///         Failed calls are tolerated (they are the failure paths); what matters is what holds after.
contract PolyneumHandler is Test {
    Polyneum public immutable token;
    address[] public actors;

    constructor(Polyneum token_, address[] memory actors_) {
        token = token_;
        actors = actors_;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        vm.prank(_actor(ownerSeed));
        token.approve(_actor(spenderSeed), amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 cap = token.allowance(owner, spender);
        uint256 bal = token.balanceOf(owner);
        if (bal < cap) cap = bal;
        amount = bound(amount, 0, cap);
        vm.prank(spender);
        token.transferFrom(owner, _actor(toSeed), amount);
    }
}

contract PolyneumInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 10 ** 18;
    address constant DEPLOYER = address(0xFAC7);

    Polyneum token;
    PolyneumHandler handler;
    address[] actors;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new Polyneum();

        actors.push(DEPLOYER);
        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA201));
        actors.push(address(0xDA7E));

        handler = new PolyneumHandler(token, actors);
        targetContract(address(handler));
    }

    function invariant_totalSupplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, SUPPLY);
    }

    function invariant_zeroAddressHoldsNothing() public view {
        assertEq(token.balanceOf(address(0)), 0);
    }
}
