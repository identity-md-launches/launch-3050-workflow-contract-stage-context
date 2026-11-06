// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Test-only Base64 decoder, used to inspect the on-chain metadata.
library Base64Decoder {
    function decode(string memory text) internal pure returns (bytes memory out) {
        bytes memory input = bytes(text);
        require(input.length % 4 == 0, "base64: bad length");
        if (input.length == 0) return out;

        uint256 padding = 0;
        if (input[input.length - 1] == "=") padding++;
        if (input[input.length - 2] == "=") padding++;

        out = new bytes((input.length / 4) * 3 - padding);
        uint256 cursor = 0;
        for (uint256 i = 0; i < input.length; i += 4) {
            uint256 chunk = (_value(input[i]) << 18) | (_value(input[i + 1]) << 12) | (_value(input[i + 2]) << 6)
                | _value(input[i + 3]);
            if (cursor < out.length) out[cursor++] = bytes1(uint8(chunk >> 16));
            if (cursor < out.length) out[cursor++] = bytes1(uint8(chunk >> 8));
            if (cursor < out.length) out[cursor++] = bytes1(uint8(chunk));
        }
    }

    function _value(bytes1 char) private pure returns (uint256) {
        uint8 c = uint8(char);
        if (c >= 65 && c <= 90) return c - 65; // A-Z
        if (c >= 97 && c <= 122) return c - 71; // a-z
        if (c >= 48 && c <= 57) return c + 4; // 0-9
        if (c == 43) return 62; // +
        if (c == 47) return 63; // /
        if (c == 61) return 0; // = (padding)
        revert("base64: bad character");
    }
}
