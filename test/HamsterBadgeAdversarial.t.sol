// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {HamsterBadge} from "src/HamsterBadge.sol";

contract BadgeReceiverProbe is IERC721Receiver {
    enum Response {
        Accept,
        WrongSelector,
        EmptyRevert,
        CustomRevert
    }

    Response public immutable response;
    uint256 public calls;
    address public operator;
    address public from;
    uint256 public tokenId;
    bytes public data;

    error Rejected(uint256 tokenId);

    constructor(Response response_) {
        response = response_;
    }

    function onERC721Received(address operator_, address from_, uint256 tokenId_, bytes calldata data_)
        external
        returns (bytes4)
    {
        ++calls;
        operator = operator_;
        from = from_;
        tokenId = tokenId_;
        data = data_;
        if (response == Response.CustomRevert) revert Rejected(tokenId_);
        if (response == Response.EmptyRevert) revert();
        if (response == Response.WrongSelector) return bytes4(0);
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract BadgeNonReceiver {}

/// @notice Authorization and callback failures must not change badge ownership or mint rights.
contract HamsterBadgeAdversarialTest is Test {
    HamsterBadge internal badge;
    address internal alice = makeAddr("badge alice");
    address internal bob = makeAddr("badge bob");
    address internal operator = makeAddr("badge operator");
    address internal stranger = makeAddr("badge stranger");

    function setUp() public {
        badge = new HamsterBadge();
        vm.prank(alice);
        badge.mint();
    }

    function test_tokenApprovalDoesNotGrantPermissionToDelegate() public {
        vm.prank(alice);
        badge.approve(operator, 1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidApprover.selector, operator));
        badge.approve(stranger, 1);
        assertEq(badge.getApproved(1), operator);
        assertEq(badge.ownerOf(1), alice);
    }

    function test_revokedTokenApprovalCannotTransfer() public {
        vm.startPrank(alice);
        badge.approve(operator, 1);
        badge.approve(address(0), 1);
        vm.stopPrank();
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, operator, 1));
        badge.transferFrom(alice, bob, 1);
        assertEq(badge.getApproved(1), address(0));
        _assertAliceStillOwnsBadge();
    }

    function test_revokedOperatorCannotTransferOrApprove() public {
        vm.startPrank(alice);
        badge.setApprovalForAll(operator, true);
        badge.setApprovalForAll(operator, false);
        vm.stopPrank();
        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, operator, 1));
        badge.transferFrom(alice, bob, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidApprover.selector, operator));
        badge.approve(stranger, 1);
        vm.stopPrank();
        assertFalse(badge.isApprovedForAll(alice, operator));
        _assertAliceStillOwnsBadge();
    }

    function test_oldOwnerAndOperatorLoseAuthorityAfterTransfer() public {
        vm.prank(alice);
        badge.setApprovalForAll(operator, true);
        vm.prank(operator);
        badge.approve(stranger, 1);
        vm.prank(stranger);
        badge.transferFrom(alice, bob, 1);

        assertEq(badge.getApproved(1), address(0));
        address[3] memory previousAuthorities = [alice, operator, stranger];
        for (uint256 i; i < previousAuthorities.length; ++i) {
            address caller = previousAuthorities[i];
            vm.startPrank(caller);
            vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, caller, 1));
            badge.transferFrom(bob, caller, 1);
            vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidApprover.selector, caller));
            badge.approve(caller, 1);
            vm.stopPrank();
        }
        assertEq(badge.ownerOf(1), bob);
        assertEq(badge.balanceOf(alice), 0);
        assertEq(badge.balanceOf(bob), 1);
    }

    function test_wrongFromRevertsAndRestoresApprovalAndBalances() public {
        vm.prank(alice);
        badge.approve(operator, 1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721IncorrectOwner.selector, stranger, 1, alice));
        badge.transferFrom(stranger, bob, 1);
        assertEq(badge.getApproved(1), operator);
        assertEq(badge.balanceOf(stranger), 0);
        _assertAliceStillOwnsBadge();
    }

    function test_selfTransferClearsTokenApprovalWithoutChangingSupplyOrMintRight() public {
        vm.prank(alice);
        badge.approve(operator, 1);
        vm.prank(operator);
        badge.transferFrom(alice, alice, 1);
        assertEq(badge.getApproved(1), address(0));
        _assertAliceStillOwnsBadge();
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, operator, 1));
        badge.transferFrom(alice, bob, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HamsterBadge.AlreadyMinted.selector, alice));
        badge.mint();
    }

    function test_zeroReceiverCannotBurnBadge() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        badge.transferFrom(alice, address(0), 1);
        _assertAliceStillOwnsBadge();
    }

    function test_zeroOwnerAndZeroOperatorAreRejected() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidOwner.selector, address(0)));
        badge.balanceOf(address(0));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidOperator.selector, address(0)));
        badge.setApprovalForAll(address(0), true);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_nonexistentTokensCannotBeTransferredApprovedOrRead(uint256 tokenId) public {
        tokenId = bound(tokenId, 2, type(uint256).max);
        bytes memory reason = abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId);
        vm.startPrank(alice);
        vm.expectRevert(reason);
        badge.transferFrom(alice, bob, tokenId);
        vm.expectRevert(reason);
        badge.approve(operator, tokenId);
        vm.expectRevert(reason);
        badge.getApproved(tokenId);
        vm.expectRevert(reason);
        badge.ownerOf(tokenId);
        vm.expectRevert(reason);
        badge.tokenURI(tokenId);
        vm.stopPrank();
        _assertAliceStillOwnsBadge();
    }

    function test_safeTransferToContractWithoutHookRollsBack() public {
        BadgeNonReceiver receiver = new BadgeNonReceiver();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(receiver)));
        badge.safeTransferFrom(alice, address(receiver), 1);
        _assertAliceStillOwnsBadge();
        assertEq(badge.balanceOf(address(receiver)), 0);
    }

    function test_safeTransferRejectedByReceiverRollsBackIncludingCallbackState() public {
        for (uint256 mode = 1; mode <= 3; ++mode) {
            BadgeReceiverProbe receiver = new BadgeReceiverProbe(BadgeReceiverProbe.Response(mode));
            vm.prank(alice);
            badge.approve(operator, 1);
            bytes memory reason = mode == 3
                ? abi.encodeWithSelector(BadgeReceiverProbe.Rejected.selector, 1)
                : abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(receiver));
            vm.prank(operator);
            vm.expectRevert(reason);
            badge.safeTransferFrom(alice, address(receiver), 1, hex"00ff");
            assertEq(receiver.calls(), 0, "rejected callback writes must roll back");
            assertEq(badge.getApproved(1), operator, "approval must survive failed transfer");
            assertEq(badge.balanceOf(address(receiver)), 0);
            assertFalse(badge.hasMinted(address(receiver)));
            _assertAliceStillOwnsBadge();
        }
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_safeTransferForwardsCallbackArgumentsAndKeepsMetadata(bytes memory data) public {
        BadgeReceiverProbe receiver = new BadgeReceiverProbe(BadgeReceiverProbe.Response.Accept);
        bytes32 metadataBefore = keccak256(bytes(badge.tokenURI(1)));
        vm.prank(alice);
        badge.approve(operator, 1);
        vm.prank(operator);
        badge.safeTransferFrom(alice, address(receiver), 1, data);
        assertEq(receiver.calls(), 1);
        assertEq(receiver.operator(), operator);
        assertEq(receiver.from(), alice);
        assertEq(receiver.tokenId(), 1);
        assertEq(receiver.data(), data);
        assertEq(badge.ownerOf(1), address(receiver));
        assertEq(badge.getApproved(1), address(0));
        assertEq(badge.balanceOf(alice), 0);
        assertEq(badge.balanceOf(address(receiver)), 1);
        assertEq(badge.totalSupply(), 1);
        assertFalse(badge.hasMinted(address(receiver)));
        assertTrue(badge.canMint(address(receiver)));
        assertEq(keccak256(bytes(badge.tokenURI(1))), metadataBefore);
    }

    function _assertAliceStillOwnsBadge() private view {
        assertEq(badge.ownerOf(1), alice);
        assertEq(badge.balanceOf(alice), 1);
        assertEq(badge.balanceOf(bob), 0);
        assertEq(badge.totalSupply(), 1);
        assertEq(badge.remainingSupply(), 9_999);
        assertTrue(badge.hasMinted(alice));
        assertFalse(badge.hasMinted(bob));
    }
}

/// @notice Reach the cap through real mints, with no fabricated storage or supply counters.
contract HamsterBadgeRealSupplyTest is Test {
    HamsterBadge internal badge;

    function setUp() public {
        badge = new HamsterBadge();
        for (uint256 i = 1; i < 10_000; ++i) {
            vm.prank(_wallet(i));
            badge.mint();
        }
    }

    function test_allTenThousandBadgesExistAndSoldOutCannotReopen() public {
        address finalMinter = _wallet(10_000);
        address latecomer = _wallet(10_001);
        assertEq(badge.totalSupply(), 9_999);
        assertEq(badge.remainingSupply(), 1);
        assertTrue(badge.canMint(finalMinter));
        vm.prank(finalMinter);
        assertEq(badge.mint(), 10_000);

        uint256 sumBalances;
        for (uint256 i = 1; i <= 10_000; ++i) {
            address holder = _wallet(i);
            assertEq(badge.ownerOf(i), holder);
            assertTrue(badge.hasMinted(holder));
            assertEq(badge.balanceOf(holder), 1);
            sumBalances += badge.balanceOf(holder);
        }
        assertEq(sumBalances, badge.totalSupply());
        assertEq(badge.remainingSupply(), 0);
        assertFalse(badge.canMint(latecomer));

        vm.prank(finalMinter);
        badge.transferFrom(finalMinter, latecomer, 10_000);
        vm.prank(latecomer);
        vm.expectRevert(HamsterBadge.MaxSupplyReached.selector);
        badge.mint();
        vm.prank(finalMinter);
        vm.expectRevert(abi.encodeWithSelector(HamsterBadge.AlreadyMinted.selector, finalMinter));
        badge.mint();

        assertFalse(badge.hasMinted(latecomer));
        assertEq(badge.balanceOf(finalMinter), 0);
        assertEq(badge.balanceOf(latecomer), 1);
        assertEq(badge.ownerOf(10_000), latecomer);
        assertEq(badge.totalSupply(), 10_000);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 10_001));
        badge.ownerOf(10_001);
    }

    function _wallet(uint256 i) private pure returns (address) {
        return address(uint160(0xB0000000 + i));
    }
}
