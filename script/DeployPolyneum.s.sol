// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {Polyneum} from "../src/Polyneum.sol";

/// @title DeployPolyneum
/// @notice Reviewable deployment logic for Polyneum. The token takes no constructor arguments, so
///         there is nothing to configure: whoever sends the creation transaction receives the whole
///         supply. On an IdentityMD launch the factory deploys the token from its bytecode and this
///         script is not used; it exists so the deployment can be exercised locally and in tests.
/// @dev    Tests call `deploy()` directly. `run()` only wraps it in a broadcast and reads nothing
///         from the environment.
contract DeployPolyneum is Script {
    /// @notice Deploys the token and returns it. Pure logic, callable from tests without a broadcast.
    function deploy() public returns (Polyneum token) {
        token = new Polyneum();
    }

    /// @notice Broadcast entry point for a manual deployment (`forge script ... --broadcast`).
    function run() external returns (Polyneum token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
