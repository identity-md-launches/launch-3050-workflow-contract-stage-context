// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Base64Encoder
/// @notice Standard (RFC 4648, padded) Base64 encoding written in plain Solidity, without assembly.
/// @dev Only used from `view` code that builds on-chain metadata, so clarity is preferred over gas.
///      Every function is `internal`, so the library is inlined and needs no linking.
library Base64Encoder {
    bytes private constant ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    /// @dev The padding character, "=".
    bytes1 private constant PADDING = 0x3d;

    /// @notice Encodes `data` as padded Base64 text.
    function encode(bytes memory data) internal pure returns (string memory) {
        uint256 length = data.length;
        if (length == 0) return "";

        bytes memory alphabet = ALPHABET;
        // Four output characters per started group of three input bytes: the rounding is intended.
        // forge-lint: disable-next-line(divide-before-multiply)
        bytes memory out = new bytes(4 * ((length + 2) / 3));
        uint256 cursor = 0;

        for (uint256 i = 0; i < length; i += 3) {
            bool hasSecond = i + 1 < length;
            bool hasThird = i + 2 < length;

            uint256 chunk = uint256(uint8(data[i])) << 16;
            if (hasSecond) chunk |= uint256(uint8(data[i + 1])) << 8;
            if (hasThird) chunk |= uint256(uint8(data[i + 2]));

            out[cursor] = alphabet[(chunk >> 18) & 0x3F];
            out[cursor + 1] = alphabet[(chunk >> 12) & 0x3F];
            out[cursor + 2] = hasSecond ? alphabet[(chunk >> 6) & 0x3F] : PADDING;
            out[cursor + 3] = hasThird ? alphabet[chunk & 0x3F] : PADDING;
            cursor += 4;
        }

        return string(out);
    }
}
