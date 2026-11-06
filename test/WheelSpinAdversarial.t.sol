// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {HamsterBadge} from "src/HamsterBadge.sol";
import {WheelSpinCheckIn} from "src/WheelSpinCheckIn.sol";

/// @dev All callback actions occur within the safe-transfer transaction, as they would on chain.
contract SpinningBadgeReceiver is IERC721Receiver {
    HamsterBadge private immutable badge;
    WheelSpinCheckIn private immutable wheel;
    bool private immutable reject;
    uint256 public callbacks;
    uint256 public mintedToken;
    uint256 public returnedStreak;
    bytes public duplicateSpinRevert;

    error RejectAfterActions();

    constructor(HamsterBadge badge_, WheelSpinCheckIn wheel_, bool reject_) {
        badge = badge_;
        wheel = wheel_;
        reject = reject_;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        require(msg.sender == address(badge), "unexpected collection");
        require(badge.ownerOf(tokenId) == address(this), "ownership must precede callback");
        ++callbacks;
        returnedStreak = wheel.spin();
        mintedToken = badge.mint(); // receiving a badge did not consume this wallet's mint
        (bool ok, bytes memory reason) = address(wheel).call(abi.encodeCall(WheelSpinCheckIn.spin, ()));
        require(!ok, "second badge must not allow second spin");
        duplicateSpinRevert = reason;
        if (reject) revert RejectAfterActions();
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract RevertingBalanceBadge {
    error BalanceUnavailable(address account);

    function balanceOf(address account) external pure returns (uint256) {
        revert BalanceUnavailable(account);
    }
}

contract MutatingBalanceBadge {
    uint256 public calls;

    function balanceOf(address) external returns (uint256) {
        ++calls;
        return 1;
    }
}

contract MalformedBalanceBadge {
    fallback(bytes calldata) external returns (bytes memory) {
        return hex"01"; // A uint256 result requires a whole ABI word.
    }
}

contract WheelSpinAdversarialTest is Test {
    HamsterBadge internal badge;
    WheelSpinCheckIn internal wheel;
    address internal alice = makeAddr("wheel alice");
    address internal bob = makeAddr("wheel bob");
    address internal operator = makeAddr("wheel operator");
    uint256 private constant START = 20_000 days;

    function setUp() public {
        badge = new HamsterBadge();
        wheel = new WheelSpinCheckIn(address(badge));
        vm.warp(START);
        vm.prank(alice);
        badge.mint();
    }

    function test_tokenApprovalAndOperatorStatusDoNotGrantHolderEligibility() public {
        vm.startPrank(alice);
        badge.approve(bob, 1);
        badge.setApprovalForAll(operator, true);
        vm.stopPrank();
        address[2] memory approved = [bob, operator];
        for (uint256 i; i < approved.length; ++i) {
            address account = approved[i];
            assertFalse(wheel.canSpin(account));
            vm.prank(account);
            vm.expectRevert(abi.encodeWithSelector(WheelSpinCheckIn.NotBadgeHolder.selector, account));
            wheel.spin();
            assertEq(wheel.totalCheckIns(account), 0);
            assertFalse(wheel.hasSpunToday(account));
        }
        assertEq(wheel.totalSpins(), 0);
        assertEq(wheel.totalParticipants(), 0);
        assertEq(wheel.leaderboardLength(), 0);
        vm.prank(operator);
        badge.transferFrom(alice, bob, 1);
        assertTrue(wheel.canSpin(bob));
        assertFalse(wheel.canSpin(operator));
        vm.prank(bob);
        assertEq(wheel.spin(), 1);
    }

    function test_multipleBadgesStillAllowOnlyOneSpinAndLastBadgeControlsEligibility() public {
        vm.prank(bob);
        badge.mint();
        vm.prank(bob);
        badge.transferFrom(bob, alice, 2);
        assertEq(badge.balanceOf(alice), 2);
        vm.prank(alice);
        assertEq(wheel.spin(), 1);
        _expectDuplicate(alice, 20_000);
        vm.prank(alice);
        badge.transferFrom(alice, bob, 1);
        _expectDuplicate(alice, 20_000);
        vm.warp(START + 1 days);
        assertTrue(wheel.canSpin(alice), "one remaining badge suffices");
        vm.prank(alice);
        assertEq(wheel.spin(), 2);
        vm.prank(alice);
        badge.transferFrom(alice, bob, 2);
        vm.warp(START + 2 days);
        assertFalse(wheel.canSpin(alice));
        bytes32 beforeState = _wheelState(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WheelSpinCheckIn.NotBadgeHolder.selector, alice));
        wheel.spin();
        assertEq(_wheelState(alice), beforeState);
        assertEq(wheel.currentStreak(alice), 2, "losing a badge does not erase past history");
        assertEq(wheel.totalSpins(), 2);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferRoundTripsCannotResetDailyLimit(uint8 cycleSeed) public {
        uint256 cycles = bound(cycleSeed, 1, 20);
        vm.prank(alice);
        wheel.spin();
        for (uint256 i; i < cycles; ++i) {
            vm.prank(alice);
            badge.transferFrom(alice, bob, 1);
            if (i == 0) {
                vm.prank(bob);
                assertEq(wheel.spin(), 1);
            } else {
                _expectDuplicate(bob, 20_000);
            }
            vm.prank(bob);
            badge.transferFrom(bob, alice, 1);
            _expectDuplicate(alice, 20_000);
        }
        assertEq(wheel.totalCheckIns(alice), 1);
        assertEq(wheel.totalCheckIns(bob), 1);
        assertEq(wheel.totalParticipants(), 2);
        assertEq(wheel.totalSpins(), 2);
        assertEq(badge.totalSupply(), 1);
        assertEq(badge.ownerOf(1), alice);
        assertFalse(badge.hasMinted(bob));
    }

    function test_receiverCanSpinDuringTransferButCannotSpinAgainAfterMinting() public {
        SpinningBadgeReceiver receiver = new SpinningBadgeReceiver(badge, wheel, false);
        vm.prank(alice);
        badge.safeTransferFrom(alice, address(receiver), 1);
        assertEq(receiver.callbacks(), 1, "mint must not invoke an extra receiver callback");
        assertEq(receiver.mintedToken(), 2);
        assertEq(receiver.returnedStreak(), 1);
        assertEq(
            receiver.duplicateSpinRevert(),
            abi.encodeWithSelector(WheelSpinCheckIn.AlreadySpunToday.selector, address(receiver), 20_000)
        );
        assertEq(badge.ownerOf(1), address(receiver));
        assertEq(badge.ownerOf(2), address(receiver));
        assertEq(badge.balanceOf(address(receiver)), 2);
        assertEq(badge.totalSupply(), 2);
        assertTrue(badge.hasMinted(address(receiver)));
        assertEq(wheel.totalSpins(), 1);
        assertEq(wheel.totalParticipants(), 1);
        assertEq(wheel.totalCheckIns(address(receiver)), 1);
        assertEq(wheel.leaderboard()[0].account, address(receiver));
        assertFalse(wheel.canSpin(address(receiver)));
    }

    function test_rejectedCallbackRollsBackNestedMintSpinLeaderboardAndApprovals() public {
        vm.prank(alice);
        wheel.spin(); // Ensure an existing leaderboard entry also survives unchanged.
        SpinningBadgeReceiver receiver = new SpinningBadgeReceiver(badge, wheel, true);
        bytes32 beforeState = _wheelState(alice);
        vm.prank(alice);
        badge.approve(operator, 1);
        vm.prank(operator);
        vm.expectRevert(SpinningBadgeReceiver.RejectAfterActions.selector);
        badge.safeTransferFrom(alice, address(receiver), 1);

        assertEq(_wheelState(alice), beforeState);
        assertEq(receiver.callbacks(), 0);
        assertEq(receiver.mintedToken(), 0);
        assertEq(badge.ownerOf(1), alice);
        assertEq(badge.balanceOf(alice), 1);
        assertEq(badge.balanceOf(address(receiver)), 0);
        assertEq(badge.getApproved(1), operator);
        assertEq(badge.totalSupply(), 1);
        assertFalse(badge.hasMinted(address(receiver)));
        assertTrue(badge.canMint(address(receiver)));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 2));
        badge.ownerOf(2);
        assertEq(wheel.totalCheckIns(address(receiver)), 0);
        assertEq(wheel.longestStreak(address(receiver)), 0);
        assertEq(wheel.currentStreak(address(receiver)), 0);
        assertEq(wheel.rankOf(address(receiver)), 0);
        assertFalse(wheel.hasSpunToday(address(receiver)));

        // The reverted callback consumed neither mint supply nor the approved operator's authority.
        vm.prank(operator);
        badge.transferFrom(alice, bob, 1);
        vm.prank(bob);
        assertEq(badge.mint(), 2);
        vm.prank(bob);
        assertEq(wheel.spin(), 1);
        assertEq(wheel.totalSpins(), 2);
    }

    function test_revertingBadgeCannotCreatePhantomParticipant() public {
        RevertingBalanceBadge broken = new RevertingBalanceBadge();
        WheelSpinCheckIn isolated = new WheelSpinCheckIn(address(broken));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RevertingBalanceBadge.BalanceUnavailable.selector, alice));
        isolated.spin();
        vm.expectRevert(abi.encodeWithSelector(RevertingBalanceBadge.BalanceUnavailable.selector, alice));
        isolated.canSpin(alice);
        _assertEmpty(isolated);
    }

    function test_balanceReadUsesStaticCallSoDependencyCannotMutate() public {
        MutatingBalanceBadge broken = new MutatingBalanceBadge();
        WheelSpinCheckIn isolated = new WheelSpinCheckIn(address(broken));
        vm.prank(alice);
        vm.expectRevert(); // EVM static context violation carries no application custom error.
        isolated.spin{gas: 200_000}();
        assertEq(broken.calls(), 0);
        _assertEmpty(isolated);
    }

    function test_malformedBalanceResponseCannotCreatePhantomParticipant() public {
        MalformedBalanceBadge broken = new MalformedBalanceBadge();
        WheelSpinCheckIn isolated = new WheelSpinCheckIn(address(broken));
        vm.prank(alice);
        vm.expectRevert(); // ABI decode rejects the truncated uint256 result.
        isolated.spin();
        _assertEmpty(isolated);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_liveStreakExpiresAtExactUtcBoundary(uint48 daySeed, uint32 offsetSeed) public {
        uint256 day = bound(daySeed, 0, uint256(type(uint48).max) - 3);
        uint256 offset = bound(offsetSeed, 0, 1 days - 1);
        vm.warp(day * 1 days + offset);
        vm.prank(alice);
        assertEq(wheel.spin(), 1);
        assertEq(wheel.lastSpinDay(alice), day);
        assertEq(wheel.nextDayStartsAt(), (day + 1) * 1 days);
        vm.warp((day + 2) * 1 days - 1);
        assertEq(wheel.currentStreak(alice), 1, "yesterday's streak stays live until midnight");
        assertEq(wheel.leaderboard()[0].currentStreak, 1);
        vm.warp((day + 2) * 1 days);
        assertEq(wheel.currentStreak(alice), 0, "one fully missed UTC day expires the streak");
        (uint256 current, uint256 longest, uint256 total,,, uint256 rank) = wheel.statsOf(alice);
        assertEq(current, 0);
        assertEq(longest, 1);
        assertEq(total, 1);
        assertEq(rank, 1);
        assertEq(wheel.leaderboard()[0].currentStreak, 0);
        assertEq(wheel.leaderboard()[0].longestStreak, 1);
        assertTrue(wheel.canSpin(alice));
        vm.prank(alice);
        assertEq(wheel.spin(), 1);
        assertEq(wheel.totalCheckIns(alice), 2);
    }

    function test_maximumRepresentableDayDoesNotWrapAndOverflowReverts() public {
        uint256 maxDay = type(uint48).max;
        vm.warp((maxDay - 1) * 1 days);
        vm.prank(alice);
        wheel.spin();
        vm.warp(maxDay * 1 days + 1 days - 1);
        assertEq(wheel.currentDay(), maxDay);
        assertEq(wheel.nextDayStartsAt(), (maxDay + 1) * 1 days);
        vm.prank(alice);
        assertEq(wheel.spin(), 2);
        _expectDuplicate(alice, maxDay);
        assertEq(wheel.lastSpinDay(alice), maxDay);
        vm.warp((maxDay + 1) * 1 days);
        bytes memory reason = abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 48, maxDay + 1);
        vm.expectRevert(reason);
        wheel.currentDay();
        vm.prank(alice);
        vm.expectRevert(reason);
        wheel.spin();
        assertEq(wheel.totalSpins(), 2);
        assertEq(wheel.totalCheckIns(alice), 2);
        assertEq(wheel.lastSpinDay(alice), maxDay);
    }

    function _expectDuplicate(address account, uint256 day) private {
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(WheelSpinCheckIn.AlreadySpunToday.selector, account, day));
        wheel.spin();
    }

    function _wheelState(address account) private view returns (bytes32) {
        (uint256 current, uint256 longest, uint256 total, uint256 lastDay, bool spunToday, uint256 rank) =
            wheel.statsOf(account);
        return keccak256(
            abi.encode(
                wheel.totalSpins(),
                wheel.totalParticipants(),
                wheel.leaderboard(),
                current,
                longest,
                total,
                lastDay,
                spunToday,
                rank
            )
        );
    }

    function _assertEmpty(WheelSpinCheckIn isolated) private view {
        assertEq(isolated.totalSpins(), 0);
        assertEq(isolated.totalParticipants(), 0);
        assertEq(isolated.leaderboardLength(), 0);
        assertEq(isolated.leaderboard().length, 0);
        assertEq(isolated.totalCheckIns(alice), 0);
        assertEq(isolated.currentStreak(alice), 0);
        assertEq(isolated.longestStreak(alice), 0);
        assertEq(isolated.lastSpinDay(alice), 0);
        assertEq(isolated.rankOf(alice), 0);
        assertFalse(isolated.hasSpunToday(alice));
    }
}
