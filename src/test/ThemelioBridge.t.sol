// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import 'forge-std/Test.sol';
import 'openzeppelin-contracts/contracts/utils/Strings.sol';
import './utils/ByteStrings.sol';
import '../ThemelioBridge.sol';

contract ThemelioBridgeTest is ThemelioBridge, Test {
    using Blake3Sol for Blake3Sol.Hasher;
    using ByteStrings for bytes;
    using Strings for uint256;

    constructor() ThemelioBridge(0, 0, 0) {}

        /* =========== Helpers =========== */

    function decodeStakeDocHelper(bytes calldata encodedStakeDoc_)
        public pure returns (bytes32, uint256, uint256, uint256) {
        StakeDoc memory decodedStakeDoc = _decodeStakeDoc(encodedStakeDoc_);

        return (
            decodedStakeDoc.publicKey,
            decodedStakeDoc.epochStart,
            decodedStakeDoc.epochPostEnd,
            decodedStakeDoc.symsStaked
        );
    }

    function decodeIntegerHelper(
        bytes calldata header,
        uint256 offset
    ) public pure returns (uint256) {
        uint256 integer = _decodeInteger(header, offset);

        return integer;
    }

    function denomToStringHelper(uint256 denom) public pure returns (string memory) {
        if (denom == MEL) {
            return "MEL";
        } else if (denom == SYM) {
            return "SYM";
        } else if (denom == ERG) {
            return "ERG";
        } else if (denom == NEWCOIN) {
            return "(NEWCOIN)";
        } else {
            string memory txHash = abi.encodePacked(denom).toHexString();
            txHash = string(_slice(abi.encodePacked(txHash), 2, 66));

            return string(abi.encodePacked("CUSTOM-", txHash));
        }
    }

    function extractTransactionsHashHelper(bytes calldata header) public pure returns (bytes32) {
        bytes32 transactionsHash = _extractTransactionsHash(header);

        return transactionsHash;
    }

    function extractValueDenomAndRecipientHelper(
        bytes calldata transaction
    ) public pure returns (uint256, uint256, address) {
        (uint256 value, uint256 denom, address recipient) = _extractValueDenomAndRecipient(transaction);

        return (value, denom, recipient);
    }

    // function relayHeaderHelper(
    //     bytes32[] calldata signers
    // ) public {
    //     uint256 blockHeight = 2106792883676695184;
    //     uint256 epoch = blockHeight / STAKE_EPOCH;
    //     uint256 signersLength = signers.length;
    //     uint256 totalSyms = 0;

    //     for (uint256 i = 0; i < signersLength; ++i) {
    //         epochs[epoch].stakers[signers[i]] = i + 30;
    //         totalSyms += i + 30;
    //     }

    //     epochs[epoch].totalStakedSyms = totalSyms;
    // }

    function computeMerkleRootHelper(
        bytes32 txHash,
        uint256 index,
        bytes32[] calldata proof
    ) public pure returns (bytes32) {
        bytes32 merkleRoot = _computeMerkleRoot(txHash, index, proof);

        return merkleRoot;
    }

    function verifyTxHelper(
        uint256 blockHeight,
        bytes32 transactionsHash,
        bytes32 stakesHash
    ) public {
        headers[blockHeight].transactionsHash = transactionsHash;
        headers[blockHeight].stakesHash = stakesHash;
    }

    function decodeIntegerDifferentialHelper(bytes calldata data)
        public pure returns (uint256) {
        return _decodeInteger(data, 0);
    }

    function extractBlockHeightHelper(bytes calldata header)
        public pure returns (uint256) {
        uint256 blockHeight = _extractBlockHeight(header);

        return blockHeight;
    }

    function bigHashFFIHelper(bytes calldata data) public pure returns (bytes32) {
        bytes32 bigHash = _hashDatablock(data);

        return bigHash;
    }

    function mintHelper(address account, uint256 id, uint256 value) public {
        _mint(account, id, value, '');
    }

        /* =========== Unit Tests =========== */

    function testEd25519() public {
        bytes memory message = abi.encodePacked('The foundation of a trustless Internet');
        bytes32 signer = 0xd82042fffbb34d09630aa9c56a2c3f0f2be196f28aaea9cc7332b509c7fc69da;
        bytes32 r = 0x8854ac521549d8d45d1743d187d8da9ea15d7ece91d0024cac14ad344a0206e2;
        bytes32 S = 0x0101137835043d999fe08b6e946cf5f120a5eaa10681dfa698c963d4ba65220c;

        bool success = Ed25519.verify(signer, r, S, message);
        assertTrue(success);
    }

    function testHashDatablock() public {
        assertEq(
            _hashDatablock(abi.encodePacked('datablock')),
            0x6ccea12fef78d2af66a4bca268cdbeccc47b3ee3ec9fbf83da1a67b526e9da2e
        );
    }

    function testHashNode() public {
        assertEq(
            _hashNodes(abi.encodePacked('node')),
            0x7b568d1038ae40d3683670f02841d47a11794b6a629c2c02fedd5856e868cc2b
        );
    }

    function testSlice() public {
        bytes memory data = abi.encodePacked(
            bytes8(0x0123456789abcdef)
        );
        uint256 start;
        uint256 end;
        bytes memory result;

        // start <= end, regular slice
        start = 2;
        end = 5;
        result = _slice(data, start, end);
        assertEq0(result, abi.encodePacked(bytes3(0x456789)));

        // start > end, reverse slice
        start = 7;
        end = 0;
        result = _slice(data, start, end);
        assertEq0(result, abi.encodePacked(bytes7(0xefcdab89674523)));
    }

    function testEncodedIntegerSize() public {
        // 250 with no padding
        bytes memory oneByteInteger = abi.encodePacked(bytes1(0xfa));
        uint256 oneByteSize = _encodedIntegerSize(oneByteInteger, 0);
        assertEq(oneByteSize, 1);

        // 251 with 1 byte of padding on both sides
        bytes memory threeByteInteger = abi.encodePacked(bytes5(0xfffbfb00ff));
        uint256 threeByteSize = _encodedIntegerSize(threeByteInteger, 1);
        assertEq(threeByteSize, 3);

        // 2**16 with 2 bytes of padding on both sides
        bytes memory fiveByteInteger = abi.encodePacked(bytes9(0xfffffc00000100ffff));
                uint256 fiveByteSize = _encodedIntegerSize(fiveByteInteger, 2);
        assertEq(fiveByteSize, 5);

        // 2**32 with 3 bytes of padding on both sides
        bytes memory nineByteInteger = abi.encodePacked(bytes15(0xfffffffd0000000001000000ffffff));
        uint256 nineByteSize = _encodedIntegerSize(nineByteInteger, 3);
        assertEq(nineByteSize, 9);

        // 2**64 with 4 bytes of padding on both sides
        bytes memory seventeenByteInteger = abi.encodePacked(
            bytes25(0xfffffffffe00000000000000000100000000000000ffffffff)
        );
        uint256 seventeenByteSize = _encodedIntegerSize(seventeenByteInteger, 4);
        assertEq(seventeenByteSize, 17);
    }

    function testExtractDenom() public {}

        /* =========== Differential FFI Fuzz Tests =========== */
    function testBlake3DifferentialFFI(bytes memory data) public {
        string[] memory cmds = new string[](3);

        cmds[0] = './src/test/differentials/target/debug/bridge_differential_tests';
        cmds[1] = '--blake3';
        cmds[2] = data.toHexString();

        bytes memory result = vm.ffi(cmds);
        bytes32 rustHash = abi.decode(result, (bytes32));

        bytes32 solHash = _hashNodes(data);

        assertEq(solHash, rustHash);
    }

    function testEd25519DifferentialFFI(bytes memory message) public {
        string[] memory cmds = new string[](3);

        cmds[0] = './src/test/differentials/target/debug/bridge_differential_tests';
        cmds[1] = '--ed25519';
        cmds[2] = message.toHexString();

        bytes memory result = vm.ffi(cmds);

        (bytes32 signer, bytes32 r, bytes32 S) = abi.decode(result, (bytes32, bytes32, bytes32));

        assertTrue(Ed25519.verify(signer, r, S, message));
    }

    function testSliceDifferentialFFI(bytes memory data, uint8 start, uint8 end) public {
        uint256 dataLength = data.length;

        if (start <= end) {
            vm.assume(start >= 0 && end <= dataLength);
        } else {
            vm.assume(start < dataLength && end >= 0);
        }

        string[] memory cmds = new string[](7);

        cmds[0] = './src/test/differentials/target/debug/bridge_differential_tests';
        cmds[1] = '--slice';
        cmds[2] = data.toHexString();
        cmds[3] = '--start';
        cmds[4] = uint256(start).toString();
        cmds[5] = '--end';
        cmds[6] = uint256(end).toString();

        bytes memory result = vm.ffi(cmds);

        bytes memory slice = _slice(data, start, end);

        assertEq(slice, result);
    }

    function testEncodedIntegerSizeDifferentialFFI(uint128 integer) public {
        string[] memory cmds = new string[](3);

        cmds[0] = './src/test/differentials/target/debug/bridge_differential_tests';
        cmds[1] = '--integer-size';
        cmds[2] = uint256(integer).toString();

        bytes memory result = vm.ffi(cmds);

        (bytes memory encodedInteger, uint256 integerSize) = abi.decode(result, (bytes, uint256));

        uint256 encodedIntegerSize = _encodedIntegerSize(encodedInteger, 0);

        assertEq(encodedIntegerSize, integerSize);
    }

    function testExtractDenomTypeDifferentialFFI() public {}
}

// contract for tests involving internal functions that have calldata params
contract ThemelioBridgeTestInternalCalldata is Test {
    using Strings for uint;
    using ByteStrings for bytes;

    uint256 constant STAKE_EPOCH = 200_000;

    uint256 constant MEL = 0;
    uint256 constant SYM = 1;

    ThemelioBridgeTest bridgeTest;

    function setUp() public {
        bridgeTest = new ThemelioBridgeTest();
    }

            /* =========== Unit Tests =========== */

    // function testApproveAndBurn() public {
    //     address burner = msg.sender;
    //     uint256 id = MEL;
    //     uint256 startBalance = bridgeTest.balanceOf(burner, id);
    //     uint256 value = 666;
    //     bytes32 themelioRecipient;

    //     bridgeTest.mintHelper(burner, id, value);

    //     assertEq(bridgeTest.balanceOf(burner, id), startBalance + value);

    //     bridgeTest.setApprovalForAll(address(this), true);

    //     bridgeTest.burn(burner, id, value, themelioRecipient);
    //     // assert log is emitted

    //     uint256 finalBalance = bridgeTest.balanceOf(burner, id);

    //     assertEq(finalBalance, startBalance);
    // }

    function testBatchBurn() public {}

    function testDecodeStakeDoc() public {
        bytes memory encodedStakeDoc = abi.encodePacked(
            bytes32(0x5dc57fc274b1235e28352d67b8ee4a30b74b5d0b070dc4400f30714cda80b280),
            bytes32(0xfd5fdd4268ccf9ed06fd481be5231b037e8efe905ff5aae270ee660c7240fe32),
            bytes3(0x05b030)
        );

        (
            bytes32 publicKey,
            uint256 epochStart,
            uint256 epochPostEnd,
            uint256 symsStaked
        ) = bridgeTest.decodeStakeDocHelper(encodedStakeDoc);

        assertEq(publicKey, 0x5dc57fc274b1235e28352d67b8ee4a30b74b5d0b070dc4400f30714cda80b280);
        assertEq(epochStart, 499329790025850207);
        assertEq(epochPostEnd, 10267647615552527176);
        assertEq(symsStaked, 64716893496921337859207055163356700560);
    }

    function testDecodeInteger() public {
        bytes memory header0 = abi.encodePacked(
            bytes1(0xfa)
        );
        uint256 integer0 = bridgeTest.decodeIntegerHelper(header0, 0);
        uint256 int0 = 0xfa;
        assertEq(integer0, int0);

        bytes memory header1 = abi.encodePacked(
            bytes4(0x00fb1111)
        );
        uint256 integer1 = bridgeTest.decodeIntegerHelper(header1, 1);
        uint256 int1 = 0x1111;
        assertEq(integer1, int1);

        bytes memory header2 = abi.encodePacked(
            bytes7(0x0000fc22222222)
        );
        uint256 integer2 = bridgeTest.decodeIntegerHelper(header2, 2);
        uint256 int2 = 0x22222222;
        assertEq(integer2, int2);

        bytes memory header3 = abi.encodePacked(
            bytes12(0x000000fd3333333333333333)
        );
        uint256 integer3 = bridgeTest.decodeIntegerHelper(header3, 3);
        uint256 int3 = 0x3333333333333333;
        assertEq(integer3, int3);

        bytes memory header4 = abi.encodePacked(
            bytes21(0x00000000fe44444444444444444444444444444444)
        );
        uint256 integer4 = bridgeTest.decodeIntegerHelper(header4, 4);
        uint256 int4 = 0x44444444444444444444444444444444;
        assertEq(integer4, int4);
    }

    function testExtractBlockHeight() public {
        bytes memory header = abi.encodePacked(
            bytes32(0xff2886e61b7756ec3fd75b0f89f3dc8d8dd2f7b44401c4e2fb55cc037980e44b),
            bytes32(0xbafd5928e58213d64dc5f1d25074f72f9e1457562e45913d8eb2ed461e1396be),
            bytes32(0x39ca087bb7de7c178811418f7da89b5e89e56ade852bc77909f5043339c1b8cc),
            bytes32(0x4b0d2060e16b824a8f44e53545413058167cef39efc8a9da6d3a620d1719fd91),
            bytes32(0x0c081d64a0f698d153cefefbffffca93a032754fe28625fc5239e5fe94c2ae0a),
            bytes32(0xef2efde355dc11aff5446783feb859bcadd36dbe0ed6e6d9d0f13d41f68fd2d0),
            bytes32(0x6c66cd36ba998c346e481522724ff71b19c04e8841616bf2afe880ca063b232b),
            bytes29(0x90a52d3801d0d9775ac49ee59050d115aeff4796c9e3d11bc010341590)
        );
        uint256 blockHeight = bridgeTest.extractBlockHeightHelper(header);

        assertEq(blockHeight, 14217254977967302745);
    }

    function testExtractTransactionsHash() public {
        bytes memory header = abi.encodePacked(
            bytes32(0xff6b91090007737cd4cc72ac2067ab3441218f0977d00039c2363867bafd2e44),
            bytes32(0xf4fda84c8c112efd7da407a7bbab3660ca201e02b3ac54ea0775839e2fb4b4f6),
            bytes32(0xf458ebef7d1bb11fff52cd0b0d522541a034493c8bce35d5c78616da0644b758),
            bytes32(0x8980bc3fd95e678b2155cc31bac5a1ce87db5f32c719f5209984d6aea2582981),
            bytes32(0x0b153d97ddb22b004f9efec8ffe0630521d94ec973dea0a1369884fec037ff47),
            bytes32(0xba4c2d0ba0167d711026711ffe026c833667f9a7602473a7b5053d4d3798d768),
            bytes32(0x161cc8276a1dcfcf68a4b63b85f9960ef20792d8260e16eb93620066c905bba0),
            bytes29(0x71d65be9bc30b11a68a0819886d2ce85b9414e00719a706a77d8bc0772)
        );

        bytes32 transactionsHash = bridgeTest.extractTransactionsHashHelper(header);

        assertEq(
            transactionsHash,
            bytes32(0xcc31bac5a1ce87db5f32c719f5209984d6aea25829810b153d97ddb22b004f9e)
        );
    }

    function testExtractDenomValueAndRecipient() public {
        bytes memory transaction = abi.encodePacked(
            bytes32(0x51010a1a82a7f70497fbbb549a63b4f11fe2062fc8eb78908138d5ec6c4c37b4),
            bytes32(0xd46d9602918b542ba2682549c3e246dc41ea843d3f7c565a45f4ee4529e314e6),
            bytes32(0xf4ababe4feea64accf835d2e8c75071bb47bc74bde016d14c505b3263fec82f8),
            bytes32(0xb624f4ba9c01b20e506b5e1e868010bfd9908ba0027dbb1f063b9ef1f20cae1f),
            bytes32(0x75e2ccc9596eac88253175b1fedd531bfa008451b726a8125afd34db9e016d00),
            bytes26(0xfe49707269c1dd7303bae99ab55ffd4db401017b02ddce010105)
        );

        (uint256 value, uint256 denom, address recipient) =
            bridgeTest.extractValueDenomAndRecipientHelper(transaction);

        assertEq(value, 295482083328956529783620102020496385258);
        assertTrue(denom == MEL);
        assertEq(recipient, 0xc505B3263fEc82F8b624f4BA9C01b20E506b5E1e);
    }

    // function testRelayHeader() public {
    //     bytes memory header = abi.encodePacked(
    //         bytes32(0xffa011c4104d79413ef82b91c5dc1d93991b144d0a5c388f56c49997cb90fe61),
    //         bytes32(0xdcfd90cade26f7d43c1dae753f62c43a2e9e8980092d74b176d44e66934e7d4f),
    //         bytes32(0x695dab16ad3709ab4ddd18e38c16fef2b41f08ca978f073fd284dc4afb38847c),
    //         bytes32(0xb429c88ca67f20e2fceac8fc42d07e3c70edb34d2580a56577e7efba232ec576),
    //         bytes32(0x53d9589ea14aeaf0a538fee973f4378fbe51d158637bed4a909ee8fe44a095b0),
    //         bytes32(0x9d5fb644423e6805bded708afe9ecbc17767c13584eb68a2f813ddfd3b099c23),
    //         bytes32(0x89c2290dd6def728f395ce85c4067636d33c2b4708872728f8308508331b73c0),
    //         bytes29(0xcee7078be495c4144b8d486a34ec81fc893d515a79ed2b1b860b381f63)
    //     );

    //     bytes32[] memory signers = new bytes32[](3);
    //     signers[0] = 0x2eb2115fe909017c0dcff17846dba5da36ccc56ddf01506a1ebca94ab0f65bc9;
    //     signers[1] = 0x419b43ad463c65f7ef872bb2eb3aa6ac5fd094351703dfed73656627b3bcdd7d;
    //     signers[2] = 0x00083c8fe73cfdb00f1c3f8998aeb87f9d2534d6ee21fc442b4fe40eba03e39e;

    //     bytes32[] memory signatures = new bytes32[](6);
    //     signatures[0] = 0xab10f3f8e8fd7987b903bee83c4d935db6e41c8cdb0149e81569b50f737fe79f;
    //     signatures[1] = 0x77f8fb24f0ebdaa0634b79358a5d576c36897eea06985a38af811e930c702702;
    //     signatures[2] = 0xd5e16061798104ca5fd82587fd499239df5f72d7a76dbabce4b0fcc90b297957;
    //     signatures[3] = 0x0fa9456df1c04d95286cd3b1cf25ba0676670171c22e5085f6346a13f2f3ae0a;
    //     signatures[4] = 0xc2a3f158b19db3c9e6be2e01578af8e49c6ce9bf158177efb2c18b558b853f40;
    //     signatures[5] = 0xd9d2aad475adf60bcf454130a1612f6128364c9d66ad7fe5eea5ca3522e16c01;

    //     bridgeTest.relayHeaderTestHelper(signers);

    //     bool success = bridgeTest.relayHeader(header, signers, signatures);
    //     assertTrue(success);
    // }

    // function testCannotRelayHeader() public {
    //     bytes memory header = abi.encodePacked(
    //         bytes32(0xffa011c4104d79413ef82b91c5dc1d93991b144d0a5c388f56c49997cb90fe61),
    //         bytes32(0xdcfd90cade26f7d43c1dae753f62c43a2e9e8980092d74b176d44e66934e7d4f),
    //         bytes32(0x695dab16ad3709ab4ddd18e38c16fef2b41f08ca978f073fd284dc4afb38847c),
    //         bytes32(0xb429c88ca67f20e2fceac8fc42d07e3c70edb34d2580a56577e7efba232ec576),
    //         bytes32(0x53d9589ea14aeaf0a538fee973f4378fbe51d158637bed4a909ee8fe44a095b0),
    //         bytes32(0x9d5fb644423e6805bded708afe9ecbc17767c13584eb68a2f813ddfd3b099c23),
    //         bytes32(0x89c2290dd6def728f395ce85c4067636d33c2b4708872728f8308508331b73c0),
    //         bytes29(0xcee7078be495c4144b8d486a34ec81fc893d515a79ed2b1b860b381f63)
    //     );

    //     bytes32[] memory signersRelayStakers = new bytes32[](3);
    //     // 30 syms staked
    //     signersRelayStakers[0] = 0x2eb2115fe909017c0dcff17846dba5da36ccc56ddf01506a1ebca94ab0f65bc9;
    //     // 31 syms staked
    //     signersRelayStakers[1] = 0x419b43ad463c65f7ef872bb2eb3aa6ac5fd094351703dfed73656627b3bcdd7d;
    //     // 32 syms staked
    //     signersRelayStakers[2] = 0x00083c8fe73cfdb00f1c3f8998aeb87f9d2534d6ee21fc442b4fe40eba03e39e;

    //     // we are only including signatures for the first 2 signers so staked syms of signers < 2/3
    //     bytes32[] memory signatures = new bytes32[](4);
    //     signatures[0] = 0xab10f3f8e8fd7987b903bee83c4d935db6e41c8cdb0149e81569b50f737fe79f;
    //     signatures[1] = 0x77f8fb24f0ebdaa0634b79358a5d576c36897eea06985a38af811e930c702702;
    //     signatures[2] = 0xd5e16061798104ca5fd82587fd499239df5f72d7a76dbabce4b0fcc90b297957;
    //     signatures[3] = 0x0fa9456df1c04d95286cd3b1cf25ba0676670171c22e5085f6346a13f2f3ae0a;

    //     // this call saves the staker information in the appropriate epoch for this test
    //     bridgeTest.relayHeaderTestHelper(signersRelayStakers);

    //     // declaring a new signers array so the size is correct in relation to the signatures array
    //     bytes32[] memory signersRelayHeader = new bytes32[](2);
    //     // 30 syms staked
    //     signersRelayHeader[0] = 0x2eb2115fe909017c0dcff17846dba5da36ccc56ddf01506a1ebca94ab0f65bc9;
    //     // 31 syms staked
    //     signersRelayHeader[1] = 0x419b43ad463c65f7ef872bb2eb3aa6ac5fd094351703dfed73656627b3bcdd7d;

    //     // expect a revert due to insufficient signatures
    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             ThemelioBridge.InsufficientSignatures.selector,
    //             61,
    //             93
    //         )
    //     );

    //     bridgeTest.relayHeader(header, signersRelayHeader, signatures);
    // }

    function testComputeMerkleRoot() public {
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = 0xccaa1158058ab1de4168de28f6bee9f2fea080042a820802699755262c8f2e5f;
        proof[1] = 0x171668289941c5ef323e451b1fd651688ca3dd96a7b91fc83fd42bc3845d7b81;

        bytes32 txHash = 0x2e187bec885cacb89e4adc7f4dd4a658d2c924464367ee9bff8c10e0821409c5;
        uint256 txIndex = 3;

        bytes32 merkleRoot = bridgeTest.computeMerkleRootHelper(
            txHash,
            txIndex,
            proof
        );

        assertEq(merkleRoot, 0xfdb8082e4be32395b895e7e46719f70c9155f426db3d2e31ce7632dced994608);
    }

    function testVerifyTx() public {
        uint256 blockHeight = 11699990686140247438;
        bytes32 transactionsHash =
            0x580997689374a72c83aaa25fd2517e1e60c17034413d513e090435941fb318ce;
        bytes32 stakesHash =
            0xf7490fc7be550aefa27eb01a33d51138deda54823601f2f87283ce88f04a5831;

        bytes memory transaction = abi.encodePacked(
            bytes32(0x5101ac47ce6d06e6b937043484412f7f8ecffc5227284f81e5d5d093d5c4c57d),
            bytes32(0x0ba71202766a5980aa7d6c7c05294d217eb09872ea8579fbb4e7ed129fa2140f),
            bytes32(0xee549cc9fe0f9c28281dfe5cca35b0647af83c3b73016d14762346cea1cb891d),
            bytes32(0xbc4b30d328598f4c9568227de69e61600cd3347a796664f34e4cb1e0b31f453b),
            bytes32(0xb8fa84e20ac43b36074a4394feb61cd4ef5a811fd2f8144b8b3f3a8a10016d00),
            bytes26(0xfe113c98493ad256720c5f8cfb32000af301018c028a8101018f)
        );
        uint256 txIndex = 3;

        bytes32[] memory proof = new bytes32[](2);
        proof[0] = 0x1a2582eb25c727ff0d4fe22c9d921e2b6186b6160a2c72f0fb8cb2e5f126bfb1;
        proof[1] = 0xf12599cbd9d49c0aad7aa00257dd4a1dd2b1a41b7b71cebc7a8217a121586339;

        uint256 value = 153168801660958298760728062610398288911;
        address recipient = 0x762346cea1cb891dbC4b30d328598F4c9568227d;

        bridgeTest.verifyTxHelper(blockHeight, transactionsHash, stakesHash);

        bool success = bridgeTest.verifyTx(transaction, txIndex, blockHeight, proof);
        assertTrue(success);

        uint256 recipientBalance = bridgeTest.balanceOf(recipient, MEL);
        assertEq(recipientBalance, value);
    }

    function testCannotVerifyTxTwice() public {
        uint256 blockHeight = 11699990686140247438;
        bytes32 transactionsHash =
            0x580997689374a72c83aaa25fd2517e1e60c17034413d513e090435941fb318ce;
        bytes32 stakesHash =
            0xf7490fc7be550aefa27eb01a33d51138deda54823601f2f87283ce88f04a5831;

        bytes memory transaction = abi.encodePacked(
            bytes32(0x5101ac47ce6d06e6b937043484412f7f8ecffc5227284f81e5d5d093d5c4c57d),
            bytes32(0x0ba71202766a5980aa7d6c7c05294d217eb09872ea8579fbb4e7ed129fa2140f),
            bytes32(0xee549cc9fe0f9c28281dfe5cca35b0647af83c3b73016d14762346cea1cb891d),
            bytes32(0xbc4b30d328598f4c9568227de69e61600cd3347a796664f34e4cb1e0b31f453b),
            bytes32(0xb8fa84e20ac43b36074a4394feb61cd4ef5a811fd2f8144b8b3f3a8a10016d00),
            bytes26(0xfe113c98493ad256720c5f8cfb32000af301018c028a8101018f)
        );
        uint256 txIndex = 3;

        bytes32[] memory proof = new bytes32[](2);
        proof[0] = 0x1a2582eb25c727ff0d4fe22c9d921e2b6186b6160a2c72f0fb8cb2e5f126bfb1;
        proof[1] = 0xf12599cbd9d49c0aad7aa00257dd4a1dd2b1a41b7b71cebc7a8217a121586339;

        uint256 value = 153168801660958298760728062610398288911;
        address recipient = 0x762346cea1cb891dbC4b30d328598F4c9568227d;

        bridgeTest.verifyTxHelper(blockHeight, transactionsHash, stakesHash);

        bool success = bridgeTest.verifyTx(transaction, txIndex, blockHeight, proof);
        assertTrue(success);

        uint256 recipientBalance = bridgeTest.balanceOf(recipient, MEL);
        assertEq(recipientBalance, value);

        // expect a revert due to already verified tx
        vm.expectRevert(
            abi.encodeWithSelector(
                ThemelioBridge.TxAlreadyVerified.selector,
                0xd0deea06e5ab0f53bd4e7c64ec733c815ab200a70d11db3dcb55553343157b7f
            )
        );

        bridgeTest.verifyTx(transaction, txIndex, blockHeight, proof);
    }

        /* =========== Differential Fuzz Tests =========== */
    function testDecodeIntegerDifferentialFFI(uint128 integer) public {
        string[] memory cmds = new string[](3);

        cmds[0] = './src/test/differentials/target/debug/bridge_differential_tests';
        cmds[1] = '--decode-integer';
        cmds[2] = uint256(integer).toString();

        bytes memory result = vm.ffi(cmds);
        uint256 decodedInteger = bridgeTest.decodeIntegerDifferentialHelper(result);

        assertEq(decodedInteger, integer);
    }

    function testExtractBlockHeightDifferentialFFI(uint128 modifierNum, uint64 blockHeight) public {
        string[] memory cmds = new string[](5);

        cmds[0] = './src/test/differentials/target/debug/bridge_differential_tests';
        cmds[1] = '--extract-block-height';
        cmds[2] = uint256(blockHeight).toString();
        cmds[3] = '--modifier';
        cmds[4] = uint256(modifierNum).toString();

        bytes memory header = vm.ffi(cmds);

        uint256 extractedBlockHeight = bridgeTest.extractBlockHeightHelper(header);

        assertEq(extractedBlockHeight, blockHeight);
    }

    function testExtractTransactionsHashDifferentialFFI(uint128 modifierNum) public {
        string[] memory cmds = new string[](3);

        cmds[0] = './src/test/differentials/target/debug/bridge_differential_tests';
        cmds[1] = '--extract-transactions-hash';
        cmds[2] = uint256(modifierNum).toString();

        bytes memory result = vm.ffi(cmds);

        (bytes memory header, bytes32 merkleRoot) = abi.decode(result, (bytes, bytes32));

        bytes32 extractedTransactionsHash = bridgeTest.extractTransactionsHashHelper(header);

        assertEq(extractedTransactionsHash, merkleRoot);
    }

    function testExtractValueDenomAndRecipientDifferentialFFI(
        uint128 value,
        uint256 denom,
        address recipient
    ) public {
        string[] memory cmds = new string[](7);

        cmds[0] = './src/test/differentials/target/debug/bridge_differential_tests';
        cmds[1] = '--extract-value';
        cmds[2] = uint256(value).toString();
        cmds[3] = '--denom';
        cmds[4] = bridgeTest.denomToStringHelper(denom);
        cmds[5] = '--recipient';
        cmds[6] = abi.encodePacked(recipient).toHexString();

        bytes memory header = vm.ffi(cmds);

        (
            uint256 extractedValue,
            uint256 extractedDenom,
            address extractedRecipient
        ) = bridgeTest.extractValueDenomAndRecipientHelper(header);

        assertEq(extractedValue, value);
        assertEq(extractedDenom, denom);
        assertEq(extractedRecipient, recipient);
    }

    function testBigHashFFI() public {
        string[] memory cmds = new string[](2);
        cmds[0] = './src/test/differentials/target/debug/bridge_differential_tests';
        cmds[1] = '--big-hash';

        bytes memory packedData = vm.ffi(cmds);
        (bytes memory data, bytes32 dataHash) = abi.decode(packedData, (bytes, bytes32));

        bytes32 bigHash = bridgeTest.bigHashFFIHelper(data);

        assertEq(bigHash, dataHash);
    }
}