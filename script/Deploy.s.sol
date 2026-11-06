// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {HamsterBadge} from "../src/HamsterBadge.sol";
import {WheelSpinCheckIn} from "../src/WheelSpinCheckIn.sol";

/// @title Deploy
/// @notice Local/dev deployment helper (for example against anvil). The public launch is done by the
///         IdentityMD launch factory from launch.json, not by this script.
/// @dev Neither contract has an owner or any configuration besides the badge address, so the result
///      does not depend on which address runs the script.
contract Deploy is Script {
    function run() external returns (HamsterBadge badge, WheelSpinCheckIn wheel) {
        vm.startBroadcast();
        (badge, wheel) = deploy();
        vm.stopBroadcast();
    }

    /// @notice Deploys the badge, then the check-in contract pointing at it.
    function deploy() public returns (HamsterBadge badge, WheelSpinCheckIn wheel) {
        badge = new HamsterBadge();
        wheel = new WheelSpinCheckIn(address(badge));
    }
}
