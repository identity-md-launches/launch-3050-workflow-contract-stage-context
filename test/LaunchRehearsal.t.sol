// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterBadge} from "../src/HamsterBadge.sol";
import {WheelSpinCheckIn} from "../src/WheelSpinCheckIn.sol";
import {Deploy} from "../script/Deploy.s.sol";

/// @dev Stands in for the launch factory: deploys every application with CREATE2 in a single call.
contract FactoryStandIn {
    function deployAll(bytes[] memory codes, bytes32[] memory salts) external returns (address[] memory deployed) {
        deployed = new address[](codes.length);
        for (uint256 i = 0; i < codes.length; ++i) {
            bytes memory code = codes[i];
            bytes32 salt = salts[i];
            address created;
            assembly ("memory-safe") {
                created := create2(0, add(code, 32), mload(code), salt)
            }
            require(created != address(0) && created.code.length > 0, "constructor failed");
            deployed[i] = created;
        }
    }

    function predict(bytes memory code, bytes32 salt) external view returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(code))))));
    }
}

/// @notice Rehearses how the launch deploys the two contracts: from their creation code, by a factory,
///         in one transaction, with the check-in contract given the badge's address as its only argument.
contract LaunchRehearsalTest is Test {
    FactoryStandIn internal factory;
    HamsterBadge internal badge;
    WheelSpinCheckIn internal wheel;

    address internal constant LAUNCH_OWNER = 0xCc2005844AeABbd4d663f7C45C9bd1369eb062b3;

    function setUp() public {
        vm.chainId(11155111);
        factory = new FactoryStandIn();

        bytes[] memory codes = new bytes[](2);
        bytes32[] memory salts = new bytes32[](2);
        salts[0] = keccak256("HamsterBadge");
        salts[1] = keccak256("WheelSpinCheckIn");

        codes[0] = type(HamsterBadge).creationCode;
        address predictedBadge = factory.predict(codes[0], salts[0]);
        codes[1] = abi.encodePacked(type(WheelSpinCheckIn).creationCode, abi.encode(predictedBadge));

        address[] memory deployed = factory.deployAll(codes, salts);
        assertEq(deployed[0], predictedBadge);
        badge = HamsterBadge(deployed[0]);
        wheel = WheelSpinCheckIn(deployed[1]);
    }

    function test_launch_contractsAreWiredTogether() public view {
        assertEq(address(wheel.badge()), address(badge));
        assertEq(badge.name(), "Hamster Badge");
        assertEq(badge.symbol(), "HBADGE");
        assertEq(badge.totalSupply(), 0);
    }

    function test_launch_factoryGetsNoTokensAndNoPrivileges() public {
        assertEq(badge.balanceOf(address(factory)), 0);
        assertFalse(badge.hasMinted(address(factory)));

        // Neither contract has an owner at all, so neither the factory nor anyone else can hold one.
        (bool ok,) = address(badge).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        (ok,) = address(wheel).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
    }

    function test_launch_ownerWalletIsAnOrdinaryUser() public {
        vm.warp(20_398 days);
        vm.startPrank(LAUNCH_OWNER);
        assertEq(badge.mint(), 1);
        assertEq(wheel.spin(), 1);
        vm.expectRevert(abi.encodeWithSelector(HamsterBadge.AlreadyMinted.selector, LAUNCH_OWNER));
        badge.mint();
        vm.stopPrank();
    }

    function test_launch_endToEndUserJourney() public {
        vm.warp(20_398 days + 9 hours);
        address visitor = makeAddr("visitor");

        vm.startPrank(visitor);
        assertFalse(wheel.canSpin(visitor));
        badge.mint();
        assertTrue(wheel.canSpin(visitor));
        wheel.spin();
        vm.stopPrank();

        (uint256 current, uint256 longest, uint256 total,, bool spunToday, uint256 rank) = wheel.statsOf(visitor);
        assertEq(current, 1);
        assertEq(longest, 1);
        assertEq(total, 1);
        assertTrue(spunToday);
        assertEq(rank, 1);
        assertEq(wheel.leaderboard()[0].account, visitor);
    }

    /// @dev Same scan the launch floor applies: no DELEGATECALL, CALLCODE or SELFDESTRUCT in reachable code,
    ///      and a runtime within the EIP-170 size limit.
    function test_launch_runtimeIsBoundedAndHasNoEscapeOpcodes() public view {
        _scan(address(badge).code);
        _scan(address(wheel).code);
    }

    function test_launch_creationCodeFitsInitCodeLimit() public pure {
        assertLe(type(HamsterBadge).creationCode.length, 49_152);
        assertLe(type(WheelSpinCheckIn).creationCode.length + 32, 49_152);
    }

    function test_deployScript_deploysAndWiresBothContracts() public {
        Deploy script = new Deploy();
        (HamsterBadge scriptBadge, WheelSpinCheckIn scriptWheel) = script.deploy();
        assertEq(address(scriptWheel.badge()), address(scriptBadge));
        assertEq(scriptBadge.totalSupply(), 0);
        assertEq(scriptBadge.balanceOf(address(script)), 0);
    }

    function _scan(bytes memory code) internal pure {
        assertGt(code.length, 0, "missing runtime");
        assertLe(code.length, 24_576, "runtime exceeds EIP-170");
        bool reachable = true;
        for (uint256 j = 0; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) reachable = false;
        }
    }
}
