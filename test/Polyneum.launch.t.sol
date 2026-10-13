// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Polyneum} from "../src/Polyneum.sol";

/// @notice Stands in for ProjectFactory.launchCustom: deploys the token through CREATE2 so the
///         token's constructor sees the factory as `msg.sender`, then performs the launch flows
///         (swarm share to the distributor, remainder onward) with plain transfers. Only the test
///         may drive it. The Uniswap v4 seed and swap are not reproduced here (v4-core is not a
///         dependency of this repository); the token has no transfer hooks, so what is checked is
///         that every flow moves exactly what it says from the factory's address.
contract FactoryProbe {
    address private immutable controller = msg.sender;

    modifier onlyController() {
        require(msg.sender == controller, "not the harness");
        _;
    }

    function deploy(bytes memory code, bytes32 salt) external onlyController returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "constructor failed");
    }

    function move(Polyneum token, address to, uint256 amount) external onlyController returns (bool) {
        return token.transfer(to, amount);
    }

    function raw(address target, bytes calldata data) external onlyController returns (bool ok) {
        (ok,) = target.call(data);
    }
}

/// @notice The launch floor, as far as it can be checked without the pool manager: the manifest's
///         supply is minted to the factory, the swarm's share arrives and is claimable whole, the
///         requester's remainder arrives whole, nothing grows the supply afterwards, and no call
///         from the factory moves or freezes a holder. Mirrors the shape of the protected harness.
contract PolyneumLaunchTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 constant SWARM_BPS = 1_000;
    uint256 constant POOL_BPS = 8_800;
    uint64 constant LAUNCH_NUMBER = 7;

    address constant DISTRIBUTOR = address(0xD157);
    address constant CLAIMANT = address(0xC1A1);
    address constant POOL = address(0x900C);
    address constant REMAINDER_TO = address(0x4E3A);
    address constant HOLDER = address(0x401D);
    address constant OTHER = address(0x07E5);

    FactoryProbe factory;
    Polyneum token;

    function setUp() public {
        factory = new FactoryProbe();
        token = Polyneum(factory.deploy(type(Polyneum).creationCode, bytes32(uint256(LAUNCH_NUMBER))));
    }

    // ---------------------------------------------------------------------------------------------
    // Deployment through the factory
    // ---------------------------------------------------------------------------------------------

    function test_create2AddressIsPredictableFromCreationCodeAlone() public view {
        // No constructor arguments: the creation code is the whole init code, so the address the
        // factory will get is a pure function of (factory, salt, creationCode).
        bytes32 initHash = keccak256(type(Polyneum).creationCode);
        address predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(factory), bytes32(uint256(LAUNCH_NUMBER)), initHash)
                    )
                )
            )
        );
        assertEq(address(token), predicted);
    }

    function test_mintsTheWholeSupplyToTheFactory() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0, "the harness, not the factory, received the supply");
        assertEq(token.decimals(), 18);
    }

    function test_creationCodeHasNoConstructorArguments() public {
        // Appending arguments the factory will not pass must not change what gets deployed; the
        // token ignores trailing bytes, so this is the manifest's "constructorArgs: []" in action.
        FactoryProbe other = new FactoryProbe();
        address withArgs =
            other.deploy(abi.encodePacked(type(Polyneum).creationCode, abi.encode(address(1))), bytes32(0));
        assertEq(Polyneum(withArgs).balanceOf(address(other)), SUPPLY);
        assertEq(withArgs.code, address(token).code, "runtime differs");
    }

    function test_redeployingWithTheSameSaltFails() public {
        vm.expectRevert(bytes("constructor failed"));
        factory.deploy(type(Polyneum).creationCode, bytes32(uint256(LAUNCH_NUMBER)));
    }

    // ---------------------------------------------------------------------------------------------
    // Launch flows: whole in, whole out
    // ---------------------------------------------------------------------------------------------

    function test_swarmShareArrivesWholeAndIsClaimableWhole() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        assertTrue(factory.move(token, DISTRIBUTOR, swarm));
        assertEq(token.balanceOf(DISTRIBUTOR), swarm, "the swarm's share arrived short");

        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(CLAIMANT, swarm));
        assertEq(token.balanceOf(CLAIMANT), swarm, "a claim arrived short");
        assertEq(token.balanceOf(DISTRIBUTOR), 0, "the distributor kept something back");
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_fullLaunchSplitLeavesNothingBehind() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        uint256 pool = (SUPPLY * POOL_BPS) / 10_000;
        uint256 remainder = SUPPLY - swarm - pool;

        factory.move(token, DISTRIBUTOR, swarm);
        factory.move(token, POOL, pool);
        factory.move(token, REMAINDER_TO, remainder);

        assertEq(token.balanceOf(DISTRIBUTOR), swarm);
        assertEq(token.balanceOf(POOL), pool);
        assertEq(token.balanceOf(REMAINDER_TO), remainder);
        assertEq(token.balanceOf(address(factory)), 0, "the factory kept something back");
        assertEq(swarm + pool + remainder, SUPPLY);
    }

    function test_factoryCannotPayOutMoreThanItHolds() public {
        factory.move(token, DISTRIBUTOR, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(Polyneum.InsufficientBalance.selector, address(factory), 0, 1));
        factory.move(token, POOL, 1);
    }

    /// @dev Many small claims from the distributor sum exactly to the share: no rounding, no fee.
    function testFuzz_manyClaimsSumExactly(uint8 claimants, uint256 seed) public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        factory.move(token, DISTRIBUTOR, swarm);
        uint256 n = bound(uint256(claimants), 1, 64);
        uint256 remaining = swarm;
        uint256 paid;
        for (uint256 i; i < n; ++i) {
            uint256 share = i + 1 == n ? remaining : bound(uint256(keccak256(abi.encode(seed, i))), 0, remaining);
            address claimant = address(uint160(0x1000 + i));
            vm.prank(DISTRIBUTOR);
            token.transfer(claimant, share);
            assertEq(token.balanceOf(claimant), share);
            paid += share;
            remaining -= share;
        }
        assertEq(paid, swarm);
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // After launch: the supply may not grow, and no hand moves a holder
    // ---------------------------------------------------------------------------------------------

    function test_noCommonAdminCallIncreasesSupplyFromStrangerOrFactory() public {
        address attacker = address(0xBEEF);
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
            assertFalse(factory.raw(address(token), data), signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
        }
    }

    function test_noPrivilegedHandMovesOrFreezesAHolder() public {
        factory.move(token, HOLDER, SUPPLY / 1_000);
        uint256 held = token.balanceOf(HOLDER);
        assertGt(held, 0);

        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            assertFalse(
                factory.raw(address(token), abi.encodeWithSignature(signatures[i], HOLDER, true)), signatures[i]
            );
        }
        // The factory, which deployed the token and held the whole supply, has no allowance over a holder.
        assertFalse(factory.raw(address(token), abi.encodeCall(token.transferFrom, (HOLDER, address(factory), 1))));
        assertEq(token.balanceOf(HOLDER), held, "a privileged call moved the holder's balance");

        vm.prank(HOLDER);
        assertTrue(token.transfer(OTHER, held / 2), "the holder can no longer transfer");
        assertEq(token.balanceOf(OTHER), held / 2);
        assertEq(token.balanceOf(HOLDER), held - held / 2);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
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
}
