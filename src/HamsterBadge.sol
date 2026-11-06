// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64Encoder} from "./libraries/Base64Encoder.sol";

/// @title Hamster Badge (HBADGE)
/// @notice The SqueekBoard membership badge: an ERC-721 collection capped at 10,000 tokens.
///         Every wallet may mint exactly one badge for free (the caller pays gas only).
/// @dev Design notes:
///      - There is no owner, admin, pause, upgrade path or privileged mint. Nothing about the
///        collection can be changed after deployment, and nobody can mint past `MAX_SUPPLY`.
///      - Tokens cannot be burned, so `totalSupply` is both "minted so far" and "in existence".
///      - Token ids are sequential, starting at 1 and ending at `MAX_SUPPLY`.
///      - Metadata is generated fully on-chain, so it needs no hosting and no owner-set base URI.
///      - `mint` is not payable and the contract has no payable function: it never holds ETH.
contract HamsterBadge is ERC721 {
    using Strings for uint256;

    /// @notice Hard cap on the number of badges that can ever exist.
    uint256 public constant MAX_SUPPLY = 10_000;

    /// @notice Number of badges minted so far (also the id of the most recently minted badge).
    uint256 public totalSupply;

    /// @notice Whether `account` has already used its one free mint.
    /// @dev Stays true forever, even if the wallet later transfers its badge away.
    mapping(address account => bool used) public hasMinted;

    /// @notice The caller already used its one free mint.
    error AlreadyMinted(address account);

    /// @notice All `MAX_SUPPLY` badges have been minted.
    error MaxSupplyReached();

    constructor() ERC721("Hamster Badge", "HBADGE") {}

    /// @notice Mints one badge to the caller, free of charge. One mint per wallet, ever.
    /// @dev Uses `_mint` rather than `_safeMint` on purpose: the recipient is always the caller, who
    ///      asked for the token, and skipping the receiver callback means this function makes no
    ///      external call at all (no reentrancy surface, and smart accounts without an
    ///      `onERC721Received` hook can still mint).
    /// @return tokenId The id of the badge minted to the caller.
    function mint() external returns (uint256 tokenId) {
        address account = msg.sender;
        if (hasMinted[account]) revert AlreadyMinted(account);

        uint256 minted = totalSupply;
        if (minted >= MAX_SUPPLY) revert MaxSupplyReached();

        hasMinted[account] = true;
        tokenId = minted + 1;
        totalSupply = tokenId;

        // forge-lint: disable-next-line(unsafe-oz-erc721-mint)
        _mint(account, tokenId);
    }

    /// @notice Number of badges that can still be minted.
    function remainingSupply() external view returns (uint256) {
        return MAX_SUPPLY - totalSupply;
    }

    /// @notice Whether `account` could mint right now (has not minted yet and supply remains).
    function canMint(address account) external view returns (bool) {
        return !hasMinted[account] && totalSupply < MAX_SUPPLY;
    }

    /// @notice On-chain metadata for `tokenId` as a `data:application/json;base64,` URI.
    /// @dev Reverts with `ERC721NonexistentToken` for ids that have not been minted.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        string memory id = tokenId.toString();
        string memory image = Base64Encoder.encode(bytes(_svg(id)));
        string memory json = string.concat(
            '{"name":"Hamster Badge #',
            id,
            '","description":"SqueekBoard membership badge for Squeekchain, the hamster-powered testnet. ',
            'Holders can record one wheel spin per day.","image":"data:image/svg+xml;base64,',
            image,
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64Encoder.encode(bytes(json)));
    }

    /// @dev The badge artwork: a hamster in its wheel, labelled with the token id.
    function _svg(string memory id) private pure returns (string memory) {
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">',
            '<rect width="400" height="400" rx="36" fill="#fff3d6"/>',
            '<g fill="none" stroke="#8a5a2b" stroke-width="10">',
            '<circle cx="200" cy="175" r="120"/>',
            '<path d="M200 55v240M80 175h240M115 90l170 170M285 90L115 260" stroke-width="4" opacity=".35"/>',
            "</g>",
            '<path d="M150 330l50-155 50 155" fill="none" stroke="#8a5a2b" stroke-width="10" stroke-linecap="round"/>',
            '<ellipse cx="200" cy="235" rx="62" ry="44" fill="#e8a65a"/>',
            '<circle cx="248" cy="205" r="30" fill="#e8a65a"/>',
            '<circle cx="236" cy="178" r="10" fill="#c9833a"/>',
            '<circle cx="262" cy="180" r="10" fill="#c9833a"/>',
            '<circle cx="257" cy="202" r="4" fill="#3b2412"/>',
            '<circle cx="276" cy="212" r="4" fill="#d9607a"/>',
            '<ellipse cx="205" cy="246" rx="34" ry="22" fill="#fbe3bd"/>',
            '<text x="200" y="372" text-anchor="middle" font-family="monospace" font-size="26" fill="#5b3a1a">',
            "Hamster Badge #",
            id,
            "</text></svg>"
        );
    }
}
