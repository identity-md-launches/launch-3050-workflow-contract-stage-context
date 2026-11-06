// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Base64Encoder} from "../src/libraries/Base64Encoder.sol";

contract Base64EncoderTest is Test {
    function test_encode_rfc4648Vectors() public pure {
        assertEq(Base64Encoder.encode(""), "");
        assertEq(Base64Encoder.encode("f"), "Zg==");
        assertEq(Base64Encoder.encode("fo"), "Zm8=");
        assertEq(Base64Encoder.encode("foo"), "Zm9v");
        assertEq(Base64Encoder.encode("foob"), "Zm9vYg==");
        assertEq(Base64Encoder.encode("fooba"), "Zm9vYmE=");
        assertEq(Base64Encoder.encode("foobar"), "Zm9vYmFy");
    }

    function test_encode_usesFullAlphabet() public pure {
        // 0xfbff encodes to characters 62 ('+') and 63 ('/') of the standard alphabet.
        assertEq(Base64Encoder.encode(hex"fbff"), "+/8=");
        assertEq(Base64Encoder.encode(hex"000000"), "AAAA");
        assertEq(Base64Encoder.encode(hex"ffffff"), "////");
    }

    function testFuzz_encode_matchesReferenceEncoder(bytes memory data) public pure {
        assertEq(Base64Encoder.encode(data), vm.toBase64(data));
    }

    function testFuzz_encode_outputLength(bytes memory data) public pure {
        assertEq(bytes(Base64Encoder.encode(data)).length, 4 * ((data.length + 2) / 3));
    }
}
