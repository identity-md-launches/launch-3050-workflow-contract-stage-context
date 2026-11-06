// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {HamsterBadge} from "../src/HamsterBadge.sol";
import {Base64Decoder} from "./utils/Base64Decoder.sol";

/// @dev A contract account with no `onERC721Received` hook.
contract PlainContractMinter {
    function mintFrom(HamsterBadge badge) external returns (uint256) {
        return badge.mint();
    }

    function send(HamsterBadge badge, address to, uint256 tokenId) external {
        badge.transferFrom(address(this), to, tokenId);
    }
}

contract HamsterBadgeTest is Test {
    using stdStorage for StdStorage;

    HamsterBadge internal badge;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    function setUp() public {
        badge = new HamsterBadge();
    }

    function _minter(uint256 i) internal pure returns (address) {
        return address(uint160(0xBAD6E0000000 + i));
    }

    // ───────────────────────────── collection facts ─────────────────────────────

    function test_metadata_nameSymbolAndCap() public view {
        assertEq(badge.name(), "Hamster Badge");
        assertEq(badge.symbol(), "HBADGE");
        assertEq(badge.MAX_SUPPLY(), 10_000);
        assertEq(badge.totalSupply(), 0);
        assertEq(badge.remainingSupply(), 10_000);
    }

    function test_supportsInterface() public view {
        assertTrue(badge.supportsInterface(type(IERC165).interfaceId));
        assertTrue(badge.supportsInterface(type(IERC721).interfaceId));
        assertTrue(badge.supportsInterface(type(IERC721Metadata).interfaceId));
        assertFalse(badge.supportsInterface(0xffffffff));
    }

    // ───────────────────────────────── minting ─────────────────────────────────

    function test_mint_givesCallerTokenOne() public {
        assertTrue(badge.canMint(alice));

        vm.expectEmit(true, true, true, true, address(badge));
        emit Transfer(address(0), alice, 1);
        vm.prank(alice);
        uint256 tokenId = badge.mint();

        assertEq(tokenId, 1);
        assertEq(badge.ownerOf(1), alice);
        assertEq(badge.balanceOf(alice), 1);
        assertEq(badge.totalSupply(), 1);
        assertEq(badge.remainingSupply(), 9_999);
        assertTrue(badge.hasMinted(alice));
        assertFalse(badge.canMint(alice));
    }

    function test_mint_idsAreSequential() public {
        vm.prank(alice);
        assertEq(badge.mint(), 1);
        vm.prank(bob);
        assertEq(badge.mint(), 2);
        vm.prank(carol);
        assertEq(badge.mint(), 3);

        assertEq(badge.ownerOf(2), bob);
        assertEq(badge.ownerOf(3), carol);
        assertEq(badge.totalSupply(), 3);
    }

    function test_mint_revertsOnSecondMintFromSameWallet() public {
        vm.startPrank(alice);
        badge.mint();
        vm.expectRevert(abi.encodeWithSelector(HamsterBadge.AlreadyMinted.selector, alice));
        badge.mint();
        vm.stopPrank();

        assertEq(badge.totalSupply(), 1);
        assertEq(badge.balanceOf(alice), 1);
    }

    function test_mint_revertsOnSecondMintEvenAfterTransferringBadgeAway() public {
        vm.startPrank(alice);
        badge.mint();
        badge.transferFrom(alice, bob, 1);
        assertEq(badge.balanceOf(alice), 0);

        vm.expectRevert(abi.encodeWithSelector(HamsterBadge.AlreadyMinted.selector, alice));
        badge.mint();
        vm.stopPrank();
    }

    function test_mint_receivingABadgeDoesNotUseUpTheFreeMint() public {
        vm.prank(alice);
        badge.mint();
        vm.prank(alice);
        badge.transferFrom(alice, bob, 1);

        assertFalse(badge.hasMinted(bob));
        vm.prank(bob);
        assertEq(badge.mint(), 2);
        assertEq(badge.balanceOf(bob), 2);
    }

    function test_mint_isFree_rejectsEth() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(badge).call{value: 1 wei}(abi.encodeCall(HamsterBadge.mint, ()));
        assertFalse(ok, "mint must not accept ETH");
        assertEq(badge.totalSupply(), 0);
        assertEq(address(badge).balance, 0);
    }

    function test_contract_rejectsPlainEthAndUnknownCalls() public {
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        (bool ok,) = address(badge).call{value: 1 wei}("");
        assertFalse(ok, "no receive function");
        (ok,) = address(badge).call(abi.encodeWithSignature("mint(address)", alice));
        assertFalse(ok, "no mint-to function");
        (ok,) = address(badge).call(abi.encodeWithSignature("mint(uint256)", 5));
        assertFalse(ok, "no batch mint function");
        (ok,) = address(badge).call(abi.encodeWithSignature("burn(uint256)", 1));
        assertFalse(ok, "no burn function");
        vm.stopPrank();
    }

    function test_contract_hasNoOwnerOrAdminSurface() public {
        (bool ok,) = address(badge).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "no owner()");
        (ok,) = address(badge).call(abi.encodeWithSignature("setBaseURI(string)", "ipfs://x/"));
        assertFalse(ok, "no setBaseURI");
        (ok,) = address(badge).call(abi.encodeWithSignature("pause()"));
        assertFalse(ok, "no pause");
    }

    function test_mint_contractWithoutReceiverHookCanMintAndMoveItsBadge() public {
        PlainContractMinter minter = new PlainContractMinter();
        uint256 tokenId = minter.mintFrom(badge);
        assertEq(badge.ownerOf(tokenId), address(minter));

        minter.send(badge, alice, tokenId);
        assertEq(badge.ownerOf(tokenId), alice);
    }

    function test_mint_firstFiveHundredWalletsMintSequentially() public {
        for (uint256 i = 0; i < 500; ++i) {
            vm.prank(_minter(i));
            assertEq(badge.mint(), i + 1);
        }
        assertEq(badge.totalSupply(), 500);
        assertEq(badge.remainingSupply(), 9_500);
        assertEq(badge.ownerOf(500), _minter(499));
    }

    function test_mint_capIsExactlyTenThousand() public {
        // Fast-forward the mint counter to ten below the cap (minting all 10,000 for real would use
        // close to the default per-test gas limit), then mint the last ten badges for real.
        stdstore.target(address(badge)).sig("totalSupply()").checked_write(9_990);
        assertEq(badge.remainingSupply(), 10);

        for (uint256 i = 0; i < 10; ++i) {
            assertTrue(badge.canMint(_minter(i)));
            vm.prank(_minter(i));
            assertEq(badge.mint(), 9_991 + i);
        }

        assertEq(badge.totalSupply(), 10_000);
        assertEq(badge.totalSupply(), badge.MAX_SUPPLY());
        assertEq(badge.remainingSupply(), 0);
        assertEq(badge.ownerOf(10_000), _minter(9));
        assertFalse(badge.canMint(alice));

        // A fresh wallet cannot mint past the cap ...
        vm.prank(alice);
        vm.expectRevert(HamsterBadge.MaxSupplyReached.selector);
        badge.mint();
        assertFalse(badge.hasMinted(alice));

        // ... and token 10,001 does not exist.
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 10_001));
        badge.ownerOf(10_001);
        assertEq(badge.totalSupply(), 10_000);

        // Freeing up a balance by transferring does not free up supply.
        vm.prank(_minter(0));
        badge.transferFrom(_minter(0), bob, 9_991);
        vm.prank(bob);
        vm.expectRevert(HamsterBadge.MaxSupplyReached.selector);
        badge.mint();

        // A wallet that already minted gets the "already minted" reason, sold out or not.
        vm.prank(_minter(3));
        vm.expectRevert(abi.encodeWithSelector(HamsterBadge.AlreadyMinted.selector, _minter(3)));
        badge.mint();
        assertEq(badge.totalSupply(), 10_000);
    }

    function testFuzz_mint_neverExceedsCap(uint256 alreadyMinted, uint8 attempts) public {
        alreadyMinted = bound(alreadyMinted, 9_900, 10_000);
        stdstore.target(address(badge)).sig("totalSupply()").checked_write(alreadyMinted);

        for (uint256 i = 0; i < attempts; ++i) {
            bool supplyLeft = badge.totalSupply() < 10_000;
            vm.prank(_minter(i));
            if (supplyLeft) {
                badge.mint();
            } else {
                vm.expectRevert(HamsterBadge.MaxSupplyReached.selector);
                badge.mint();
            }
            assertLe(badge.totalSupply(), 10_000);
        }
        uint256 expected = alreadyMinted + attempts > 10_000 ? 10_000 : alreadyMinted + attempts;
        assertEq(badge.totalSupply(), expected);
    }

    function testFuzz_mint_onePerWalletWhateverTheCallOrder(uint8[40] memory callers) public {
        uint256 expectedSupply = 0;
        for (uint256 i = 0; i < callers.length; ++i) {
            address caller = _minter(callers[i] % 16);
            bool already = badge.hasMinted(caller);

            vm.prank(caller);
            if (already) {
                vm.expectRevert(abi.encodeWithSelector(HamsterBadge.AlreadyMinted.selector, caller));
                badge.mint();
            } else {
                uint256 tokenId = badge.mint();
                expectedSupply += 1;
                assertEq(tokenId, expectedSupply);
                assertEq(badge.ownerOf(tokenId), caller);
            }
            assertEq(badge.balanceOf(caller), 1);
            assertEq(badge.totalSupply(), expectedSupply);
        }
    }

    function testFuzz_mint_anyWalletGetsExactlyOne(address caller) public {
        vm.assume(caller != address(0));
        vm.prank(caller);
        uint256 tokenId = badge.mint();
        assertEq(badge.ownerOf(tokenId), caller);
        assertEq(badge.balanceOf(caller), 1);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(HamsterBadge.AlreadyMinted.selector, caller));
        badge.mint();
    }

    // ──────────────────────────────── transfers ────────────────────────────────

    function test_transfer_standardErc721Rules() public {
        vm.prank(alice);
        badge.mint();

        // A stranger cannot move Alice's badge.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, bob, 1));
        badge.transferFrom(alice, bob, 1);

        // An approved operator can.
        vm.prank(alice);
        badge.approve(bob, 1);
        vm.prank(bob);
        badge.transferFrom(alice, carol, 1);
        assertEq(badge.ownerOf(1), carol);
        assertEq(badge.totalSupply(), 1);
    }

    // ──────────────────────────────── metadata ─────────────────────────────────

    function test_tokenURI_revertsForUnmintedToken() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        badge.tokenURI(1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        badge.tokenURI(0);
    }

    function test_tokenURI_isSelfContainedJsonWithSvgImage() public {
        vm.prank(alice);
        badge.mint();
        vm.prank(bob);
        badge.mint();

        _assertMetadata(1);
        _assertMetadata(2);
    }

    function _assertMetadata(uint256 tokenId) internal {
        string memory id = vm.toString(tokenId);
        string memory json = _stripPrefix(badge.tokenURI(tokenId), "data:application/json;base64,");
        json = string(Base64Decoder.decode(json));

        assertEq(vm.parseJsonString(json, ".name"), string.concat("Hamster Badge #", id));
        assertGt(bytes(vm.parseJsonString(json, ".description")).length, 0);

        string memory svg = _stripPrefix(vm.parseJsonString(json, ".image"), "data:image/svg+xml;base64,");
        svg = string(Base64Decoder.decode(svg));
        assertTrue(vm.contains(svg, '<svg xmlns="http://www.w3.org/2000/svg"'), "svg root");
        assertTrue(vm.contains(svg, string.concat("Hamster Badge #", id, "</text></svg>")), "svg label");
    }

    function _stripPrefix(string memory text, string memory prefix) internal pure returns (string memory) {
        bytes memory t = bytes(text);
        bytes memory p = bytes(prefix);
        require(t.length >= p.length, "shorter than prefix");
        for (uint256 i = 0; i < p.length; ++i) {
            require(t[i] == p[i], "prefix mismatch");
        }
        bytes memory rest = new bytes(t.length - p.length);
        for (uint256 i = 0; i < rest.length; ++i) {
            rest[i] = t[p.length + i];
        }
        return string(rest);
    }
}
