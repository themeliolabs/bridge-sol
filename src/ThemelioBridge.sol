// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import 'blake3-sol/Blake3Sol.sol';
import 'ed25519-sol/Ed25519.sol';
import 'openzeppelin-contracts-upgradeable/contracts/token/ERC1155/ERC1155Upgradeable.sol';
import 'openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol';

/**
* @title ThemelioBridge: A bridge for transferring Themelio assets to Ethereum and back
*
* @author Marco Serrano (https://github.com/sadministrator)
*
* @notice This contract is a Themelio SPV client which allows users to submit Themelio staker sets,
*         block headers, and transactions for the purpose of creating tokenized versions of
*         Themelio assets, on the Ethereum network, which have previously been locked up in a
*         sister contract which resides on the Themelio network. Check us out at
*         https://themelio.org !
*
* @dev Themelio staker sets are verified per epoch (each epoch comprising 200,000 blocks), with
*      each epoch's staker set being verified by the previous epoch's staker set using ed25519
*      signature verification (the base epoch staker set being introduced manually in the
*      constructor, the authenticity of which can be verified very easily by manually checking that
*      it coincides with the epoch's staker set on-chain).
*
*      Themelio block headers are validated by verifying that the included staker signatures
*      are authentic (using ed25519 signature verification) and that the total syms staked by all
*      stakers that signed the header are at least 2/3 of the total staked syms for that epoch.
*
*      Transactions are verified using the 'transactions_root' Merkle root of
*      their respective block headers by including a Merkle proof which is used to verify that the
*      transaction is a member of the 'transactions_root' tree. Upon successful verification of
*      a compliant transaction, the specified amount of Themelio assets are minted on the
*      Ethereum network as tokens and transferred to the address specified in the
*      'additional_data' field of the first output of the Themelio transaction.
*
*      To transfer tokenized Themelio assets back to the Themelio network the token holder must
*      burn their tokens on the Ethereum network and use the resulting transaction as a receipt
*      which must be submitted to the sister contract on the Themelio network to release the
*      locked assets.
*
*      Questions or concerns? Come chat with us on Discord! https://discord.com/invite/VedNp7EXFc
*/
contract ThemelioBridge is UUPSUpgradeable, ERC1155Upgradeable {
    using Blake3Sol for Blake3Sol.Hasher;

    // an abbreviated Themelio header with the only two fields we need for header and tx validation
    struct Header {
        bytes32 transactionsHash;
        bytes32 stakesHash;
    }

    // represents an unverified Themelio header with current votes and verified bytes offset
    struct UnverifiedHeader {
        uint128 votes;
        uint64 bytesVerified;
        uint64 stakeDocIndex;
    }

    // a Themelio object representing a single stash of staked syms
    struct StakeDoc {
        bytes32 publicKey;
        uint256 epochStart;
        uint256 epochPostEnd;
        uint256 symsStaked;
    }

    /* =========== Themelio Header Validation Storage =========== */

    // maps header block heights to Headers for verifying headers and transactions
    mapping(uint256 => Header) public headers;
    // maps keccak hashes of unverified headers to votes
    mapping(bytes32 => UnverifiedHeader) public headerLimbo;
    // maps keccak hashes of encoded StakeDoc arrays (stakes) to their corresponding blake3 hashes
    mapping(bytes32 => bytes32) internal stakesHashes;
    // keeps track of successful token mints
    mapping(bytes32 => bool) public spends;

    /* =========== Constants =========== */

    // the address of the Themelio counterpart covenant
    bytes32 internal constant THEMELIO_COVHASH = 0;

    // the number of blocks in a Themelio staking epoch
    uint256 internal constant STAKE_EPOCH = 200_000;

    // the denoms (token IDs) of coins on Themelio
    uint256 internal constant MEL = 0;
    uint256 internal constant SYM = 1;
    uint256 internal constant ERG = 2;

    // the hashing keys used when hashing datablocks and nodes, respectively
    bytes internal constant DATA_BLOCK_HASH_KEY =
        abi.encodePacked(
            bytes32(0xc811f2ef6eb6bd09fb973c747cbf349e682393ca4d8df88e5f0bcd564c10a84b)
        );
    bytes internal constant NODE_HASH_KEY =
        abi.encodePacked(
            bytes32(0xd943cb6e931507cafe2357fbe5cce15af420a84c67251eddb0bf934b7bbbef91)
        );

    /* =========== Modifiers =========== */

    modifier onlyOwner() {
        if (_msgSender() != _getAdmin()) {
            revert NotOwner();
        }

        _;
    }

    /* =========== Errors =========== */

    /**
    * Transaction sender must either be the owner or be approved by the owner of the tokens in
    * order to transfer them.
    */
    error ERC1155NotOwnerOrApproved();

    /**
    * Header at height `height` has already been verified.
    *
    * @param height Block height of the header being submitted.
    */
    error HeaderAlreadyVerified(uint256 height);

    /**
    * The header was unable to be verified. This could be because of incorrect serialization
    * of the header, incorrect verifier block height, improperly formatted data, or insufficient
    * signatures.
    */
    error HeaderNotVerified();

    /**
    * The 'covhash' (Themelio address) attribute of the first output of the submitted transaction
    * must be equal to the `THEMELIO_COVHASH` constant.
    *
    * @param covhash The covenant hash of the first output of the submitted transaction.
    */
    error InvalidCovhash(bytes32 covhash);

    /**
    * The stakes array submitted does not hash to the same value as the stakes hash of the verifier
    * at the provided height.
    */
    error InvalidStakes();

    /**
    * Header at height `verifierHeight` cannot be used to verify header at `headerHeight`.
    * Make sure that the verifying header is in the same epoch or is the last header in the
    * previous epoch.
    *
    * @param verifierHeight Block height of header that will be used to verify the header at
    *        `headerHeight` height.
    *
    * @param headerHeight Block height of header to be verified.
    */
    error InvalidVerifier(uint256 verifierHeight, uint256 headerHeight);

    /**
    * The length of the `stakes_` array must coincide with the length of the `proofs_` array and
    * the `signatures_` array must be exactly twice the length of each of the aforementioned
    * arrays.
    */
    error MalformedData();

    /**
    * The header at block height `height` has not been submitted yet. Please submit it with
    * verifyHeader() before attempting to verify transactions at that block height.
    *
    * @param height Block height of the header in which the transaction was included.
    */
    error MissingHeader(uint256 height);

    /**
    * The stakes with keccak hash `keccakStakesHash` have not been submitted yet. Please submit
    * them with verifyStakes() before attempting to verify headers with those stakes.
    *
    * @param keccakStakesHash Block height of the header in which the transaction was included.
    */
    error MissingStakes(bytes32 keccakStakesHash);

    /**
    * The chosen verifier, at block height `height`, has not yet been submitted. Try submitting
    * it with verifyHeader() or choosing a different verifier height.
    *
    * @param height Block height of the header which was unable to be verified.
    */
    error MissingVerifier(uint256 height);

    /**
    * Only the contract owner can call this function.
    */
    error NotOwner();

    /**
    * Slice is out of bounds. `start` must be less than `dataLength`. `end` must be less than
    * `dataLength` + 1.
    *
    * @param start Starting index (inclusive).
    *
    * @param end Ending index (exclusive).
    *
    * @param dataLength Length of data to be sliced.
    */
    error OutOfBoundsSlice(uint256 start, uint256 end, uint256 dataLength);

    /**
    * Transactions can only be verified once. The transaction with hash `txHash` has previously
    * been verified.
    *
    * @param txHash The hash of the transaction that has already been verified.
    */
    error TxAlreadyVerified(bytes32 txHash);

    /**
    * The transaction was unable to be verified. This could be because of incorrect serialization
    * of the transaction, incorrect block height, incorrect transaction index, or improperly
    * formatted Merkle proof.
    */
    error TxNotVerified();

    /* =========== Bridge Events =========== */

    event StakesVerified(
        bytes32 stakesHash
    );

    event HeaderVerified(
        uint256 indexed height
    );

    event TxVerified(
        uint256 indexed height,
        bytes32 indexed tx_hash
    );

    event TokensBurned(
        bytes32 indexed themelioRecipient
    );

    /**
    * @dev Initializer is responsible for initializing contract storage with a base header at 
    *      `blockHeight_` height, with `transactionsHash_` transactions hash and `stakesHash_`
    *      stakes hash, which will be used to verify subsequent headers.
    */
    function initialize(
        uint256 blockHeight_,
        bytes32 transactionsHash_,
        bytes32 stakesHash_
    ) external initializer {
        __ThemelioBridge_init(blockHeight_, transactionsHash_, stakesHash_);
    }

    function __ThemelioBridge_init(
        uint256 blockHeight_,
        bytes32 transactionsHash_,
        bytes32 stakesHash_
    ) internal onlyInitializing {
        __UUPSUpgradeable_init_unchained();
        __ERC1155_init_unchained('https://melscan.themelio.org/{id}.json');
        __ThemelioBridge_init_unchained(blockHeight_, transactionsHash_, stakesHash_);
    }

    function __ThemelioBridge_init_unchained(
        uint256 blockHeight_,
        bytes32 transactionsHash_,
        bytes32 stakesHash_
    ) internal onlyInitializing {
        _changeAdmin(_msgSender());

        headers[blockHeight_].transactionsHash = transactionsHash_;
        headers[blockHeight_].stakesHash = stakesHash_;
    }

    /* =========== ERC-1155 Functions =========== */

    /**
     * @notice This function is used to release frozen assets on Themelio by burning them first on
     *         Ethereum. You will use the blockheight and tx hash of your burn transaction as a
     *         receipt to release the funds on Themelio.
     *
     * @dev Destroys `value_` tokens of token type `id_` from `from_`
     *      Emits a {TransferSingle} event.
     *
     *      Requirements:
     *          - `from_` cannot be the zero address.
     *          - `from_` must have at least `amount_` tokens of token type `id_`.
     *
     * @param account_ The owner of the tokens to be burned.
     *
     * @param id_ The token id of the tokens to be burned.
     *
     * @param value_ An array of values of tokens to be burned, corresponding to the ids array
     *
     * @param themelioRecipient_ The Themelio recipient (technically covenant) to release the
     *        funds to on the Themelio network.
     */
    function burn(
        address account_,
        uint256 id_,
        uint256 value_,
        bytes32 themelioRecipient_
    ) external {
        if (account_ != _msgSender() && !isApprovedForAll(account_, _msgSender())) {
            revert ERC1155NotOwnerOrApproved();
        }

        _burn(account_, id_, value_);

        emit TokensBurned(themelioRecipient_);
    }

    /**
     * @notice This is the batch version of burn(), it can be used to burn an array of different
     *         token types using a corresponding array of values.
     *
     * @dev xref:ROOT:erc1155.adoc#batch-operations[Batched] version of {_burn}.
     *      Emits a {TransferBatch} and TokensBurned event.
     *
     *      Requirements:
     *          - `ids` and `amounts` must have the same length.
     *
     * @param account_ The owner of the tokens to be burned.
     *
     * @param ids_ An array of token ids
     *
     * @param values_ An array of values of tokens to be burned, corresponding to the ids array
     *
     * @param themelioRecipient_ The Themelio recipient (technically covenant) to release the
     *        funds to on the Themelio network.
     */
    function burnBatch(
        address account_,
        uint256[] calldata ids_,
        uint256[] calldata values_,
        bytes32 themelioRecipient_
    ) external {
        if (account_ != _msgSender() && !isApprovedForAll(account_, _msgSender())) {
            revert ERC1155NotOwnerOrApproved();
        }

        _burnBatch(account_, ids_, values_);

        emit TokensBurned(themelioRecipient_);
    }


    /* =========== Themelio Staker Set, Header, and Transaction Verification =========== */

    /**
    * @notice Accepts incoming Themelio staker sets and verifies them via blake3 hashing. The
    *         staker set hash is then saved to a storage mapping with a keccak256 hash of the
    *         staker set being the key.
    *
    * @dev The `stakes_` array is an array of serialized Themelio 'StakeDocs' which represent
    *      stakes in the Themelio network. They are serialized into a stakes byte array and hashed
    *      using the blake3 algorithm to create the 'stakes_hash' member present in every Themelio
    *      block header.
    *
    * @param stakes_ An array of serialized Themelio 'StakeDoc's.
    *
    * @return 'true' if header was successfully validated and stored, otherwise reverts.
    */
    function verifyStakes(
        bytes calldata stakes_
    ) external returns (bool) {
        bytes32 keccakStakesHash = keccak256(stakes_);
        bytes32 blake3StakesHash = _hashDatablock(stakes_);

        stakesHashes[keccakStakesHash] = blake3StakesHash;

        emit StakesVerified(blake3StakesHash);

        return true;
    }

    /**
    * @notice Accepts incoming Themelio headers, validates them by verifying the signatures of
    *         stakers in the header's epoch, and stores the header for future transaction
    *         verification, upon successful validation.
    *
    * @dev The serialized header is accompanied by an array of stakers (`signers_`) that have 
    *      signed the header. Their signatures are included in another accompanying array
    *      (`signatures_`). Each signature is checked using ed25519 verification and their staked
    *      syms are added together. If at the end of the calculations the amount of staked syms
    *      from stakers that have signed is at least 2/3 of the total staked syms for that epoch
    *      then the header is successfully validated and is stored for future transaction
    *      verifications.
    *
    * @param verifierHeight_ The height of the stored Themelio header which will be used to verify
    *        `header_`.
    *
    * @param header_ A serialized Themelio block header.
    *
    * @param stakes_ An array of serialized Themelio 'StakeDoc's.
    *
    * @param signatures_ An array of signatures of `header_` by each staker in `signers_`.
    *
    * @return 'true' if header was successfully validated, otherwise reverts.
    */
    function verifyHeader(
        uint256 verifierHeight_,
        bytes calldata header_,
        bytes calldata stakes_,
        bytes32[] calldata signatures_
    ) external returns (bool) {
        (
            uint256 blockHeight,
            bytes32 transactionsHash,
            bytes32 stakesHash
        ) = _decodeHeader(header_);
        uint256 headerEpoch = blockHeight / STAKE_EPOCH;
        uint256 verifierEpoch = verifierHeight_ / STAKE_EPOCH;

        // headers can only be used to verify headers from the same epoch, however, if they
        // are the last header of an epoch they can also verify headers one epoch ahead
        bool crossingEpoch;
        if (
            verifierEpoch != headerEpoch
        ) {
            if (verifierHeight_ != headerEpoch * STAKE_EPOCH - 1) {
                revert InvalidVerifier(verifierHeight_, blockHeight);
            } else {
                crossingEpoch = true;
            }
        }

        bytes32 verifierStakesHash = headers[verifierHeight_].stakesHash;
        if (verifierStakesHash == 0) {
            revert MissingVerifier(blockHeight);
        }

        bytes32 keccakStakesHash = keccak256(stakes_);
        bytes32 blake3StakesHash = stakesHashes[keccakStakesHash];

        if (blake3StakesHash == 0) {
            revert MissingStakes(keccakStakesHash);
        }

        if (blake3StakesHash != verifierStakesHash) {
            revert InvalidStakes();
        }

        bytes32 headerHash = keccak256(header_);
        uint256 stakeDocIndex = headerLimbo[headerHash].stakeDocIndex;
        uint256 votes;
        uint256 stakesOffset;
        if (stakeDocIndex != 0) {
            votes = headerLimbo[headerHash].votes;
            stakesOffset = headerLimbo[headerHash].bytesVerified;
        }

        // Assumption here that in a future TIP total epoch syms will be the first value in
        // 'stakes_hash' preimage and the subsequent epoch's total syms will be the second value
        uint256 totalEpochSyms;
        uint256 offset;

        if (crossingEpoch) {
            (, offset) = _decodeInteger(stakes_, 0);

            if (stakesOffset == 0) {
                stakesOffset += offset;

                (totalEpochSyms, offset) = _decodeInteger(stakes_, offset);
                stakesOffset += offset;
            } else {
                (totalEpochSyms,) = _decodeInteger(stakes_, offset);
            }
        } else {
            (totalEpochSyms, offset) = _decodeInteger(stakes_, 0);

            if(stakesOffset == 0) {
                stakesOffset += offset;

                (, offset) = _decodeInteger(stakes_, 0);
                stakesOffset += offset;
            }
        }

        StakeDoc memory stakeDoc;
        uint256 memorySizeWords;
        uint256 stakesLength = stakes_.length;

        for (; stakesOffset < stakesLength; ++stakeDocIndex) {
            (stakeDoc, stakesOffset) = _decodeStakeDoc(stakes_, stakesOffset);

            if (
                stakeDoc.epochStart <= headerEpoch &&
                stakeDoc.epochPostEnd > headerEpoch
            ) {
                // here we check if the 'R' part of the signature is zero as a way to skip
                // verification of signatures we do not have
                if (
                    signatures_[stakeDocIndex * 2] != 0 && Ed25519.verify(
                        stakeDoc.publicKey,
                        signatures_[stakeDocIndex * 2],
                        signatures_[stakeDocIndex * 2 + 1],
                        header_
                    )
                ) {
                    votes += stakeDoc.symsStaked;
                }
            }

            if (votes >= totalEpochSyms * 2 / 3) {
                headers[blockHeight].transactionsHash = transactionsHash;
                headers[blockHeight].stakesHash = stakesHash;

                delete headerLimbo[headerHash];

                emit HeaderVerified(blockHeight);

                return true;
            }

            assembly ('memory-safe') {
                memorySizeWords := div(add(mload(0x40), 31), 32)
            }

            // if not enough gas for another round, save current progress to storage
            if (gasleft() < 1_420_200 + memorySizeWords / 4) {
                headerLimbo[headerHash].votes = uint128(votes); // let's double check this
                headerLimbo[headerHash].bytesVerified = uint64(stakesOffset); // and this
                headerLimbo[headerHash].stakeDocIndex = uint64(stakeDocIndex + 1);

                return false;
            }
        }

        revert HeaderNotVerified();
    }

    /**
    * @notice Verifies the validity of a Themelio transaction by hashing it and obtaining its
    *         Merkle root using the provided Merkle proof `proof_`.
    *
    * @dev The serialized Themelio transaction is first hashed using a blake3 keyed datablock hash
    *      and then sent together with its index in the 'transactions_hash' Merkle tree,
    *      `txIndex_`, and with its Merkle proof, `proof_, to calculate its Merkle root. If its
    *      Merkle root matches the Merkle root of its corresponding header (at block
    *      `blockHeight_`), then the transaction has been validated and the 'value' field of the
    *      transaction is extracted from the first output of the transaction and the recipient is
    *      extracted from the 'additional_data' field in the first output of the transaction and
    *      the corresponding 'value' amount of tokens are minted to the Ethereum address contained
    *      in 'additional_data'.
    *
    * @param transaction_ The serialized Themelio transaction.
    *
    * @param txIndex_ The transaction's index within the 'transactions_root' Merkle tree.
    *
    * @param blockHeight_ The block height of the block header in which the transaction exists.
    *
    * @param proof_ The array of hashes which comprise the Merkle proof for the transaction.
    *
    * @return 'true' if the transaction is successfully validated, otherwise it reverts.
    */
    function verifyTx(
        bytes calldata transaction_,
        uint256 txIndex_,
        uint256 blockHeight_,
        bytes32[] calldata proof_
    ) external returns (bool) {
        bytes32 transactionsHash = headers[blockHeight_].transactionsHash;

        if (transactionsHash == 0) {
            revert MissingHeader(blockHeight_);
        }

        bytes32 txHash = _hashDatablock(transaction_);

        if(spends[txHash]) {
            revert TxAlreadyVerified(txHash);
        }

        if (_computeMerkleRoot(txHash, txIndex_, proof_) == transactionsHash) {
            spends[txHash] = true;

            (
                bytes32 covhash,
                uint256 value,
                uint256 denom,
                address recipient
            ) = _decodeTransaction(transaction_);

            if (covhash != THEMELIO_COVHASH) {
                revert InvalidCovhash(covhash);
            }

            _mint(recipient, denom, value, '');

            emit TxVerified(blockHeight_, txHash);

            return true;
        } else {
            revert TxNotVerified();
        }
    }

    /* =========== Utility Functions =========== */

    /**
    * @notice Computes and returns the datablock hash of its input.
    *
    * @dev Computes and returns the blake3 keyed hash of its input argument using as its key the
    *      blake3 hash of 'smt_datablock'.
    *
    * @param datablock The bytes of a bincode-serialized Themelio transaction that is a datablock
    *        in a 'transaction_hash' Merkle tree.
    *
    * @return The blake3 keyed hash of a Merkle tree datablock input argument.
    */
    function _hashDatablock(bytes calldata datablock) internal pure returns (bytes32) {
        Blake3Sol.Hasher memory hasher = Blake3Sol.new_keyed(DATA_BLOCK_HASH_KEY);
        hasher = hasher.update_hasher(datablock);

        return bytes32(hasher.finalize());
    }

    /**
    * @notice Computes and returns the node hash of its input.
    *
    * @dev Computes and returns the blake3 keyed hash of its input argument using as its key the
    *      blake3 hash of 'smt_node'.
    *
    * @param nodes The bytes of two concatenated hashes that are nodes in a 'transaction_hash'
    *        Merkle tree.
    *
    * @return The blake3 keyed hash of two concatenated Merkle tree nodes.
    */
    function _hashNodes(bytes memory nodes) internal pure returns (bytes32) {
        Blake3Sol.Hasher memory hasher = Blake3Sol.new_keyed(NODE_HASH_KEY);
        hasher = hasher.update_hasher(nodes);
        
        return bytes32(hasher.finalize());
    }

    /**
    * @notice Slices the `data` argument from its `start` index (inclusive) to its
    *         `end` index (exclusive), and returns the slice as a new 'bytes' array.
    *
    * @dev It can also return 'inverted slices' where `start` > `end` in order to better
    *      accomodate switching between big and little endianness in incompatible systems.
    *
    * @param data The data to be sliced, in bytes.
    *
    * @param start The start index of the slice (inclusive).
    *
    * @param end The end index of the slice (exclusive).
    *
    * @return A newly created 'bytes' variable containing the slice.
    */
    function _slice(
        bytes memory data,
        uint256 start,
        uint256 end
    ) internal pure returns (bytes memory) {
        uint256 dataLength = data.length;

        if (start <= end) {
            if (!(end <= dataLength)) {
                revert OutOfBoundsSlice(start, end, dataLength);
            }

            uint256 sliceLength = end - start;
            bytes memory dataSlice = new bytes(sliceLength);

            for (uint256 i = 0; i < sliceLength; ++i) {
                dataSlice[i] = data[start + i];
            }

            return dataSlice;
        } else {
            if (!(start < dataLength)) {
                revert OutOfBoundsSlice(start, end, dataLength);
            }

            uint256 sliceLength = start - end;
            bytes memory dataSlice = new bytes(sliceLength);

            for (uint256 i = 0; i < sliceLength; ++i) {
                dataSlice[i] = data[start - i];
            }

            return dataSlice;
        }
    }

    /**
    * @notice Decodes and returns integers encoded at a specified offset within a 'bytes' array as
    *         well as returning the encoded integer size.
    *
    * @dev Decodes and returns integers (and their sizes) encoded using the 'bincode' Rust crate
    *      with 'with_varint_encoding' and 'reject_trailing_bytes' flags set.
    *
    * @param data The data, in bytes, which contains an encoded integer.
    *
    * @param offset The offset, in bytes, where our encoded integer is located at, within `data`.
    *
    * @return The decoded integer and its size in bytes.
    */

    function _decodeInteger(
        bytes memory data,
        uint256 offset
    ) internal pure returns (uint256, uint256) {
        bytes1 lengthByte = bytes1(_slice(data, offset, offset + 1));
        uint256 integer;
        uint256 size;

        if (lengthByte < 0xfb) {
            integer = uint8(lengthByte);

            size = 1;
        } else if (lengthByte == 0xfb) {
            integer = uint16(bytes2(_slice(data, offset + 2, offset)));

            size = 3;
        } else if (lengthByte == 0xfc) {
            integer = uint32(bytes4(_slice(data, offset + 4, offset)));

            size = 5;
        } else if (lengthByte == 0xfd) {
            integer = uint64(bytes8(_slice(data, offset + 8, offset)));

            size = 9;
        } else if (lengthByte == 0xfe) {
            integer = uint128(bytes16(_slice(data, offset + 16, offset)));

            size = 17;
        } else {
            assert(false);
        }

        return (integer, size);
    }

    /**
    * @notice Decodes and returns 'StakeDoc' structs.
    *
    * @dev Decodes and returns 'StakeDoc' structs encoded using the 'bincode' Rust crate with
    *      'with_varint_encoding' and 'reject_trailing_bytes' flags set.
    *
    * @param stakeDoc The serialized 'StakeDoc' struct in bytes.
    *
    * @return The decoded 'StakeDoc'.
    */
    function _decodeStakeDoc(
        bytes calldata stakeDoc,
        uint256 offset
    ) internal pure returns (StakeDoc memory, uint256) {
        StakeDoc memory decodedStakeDoc;

        // first member of 'StakeDoc' struct is 32-byte 'public_key'
        decodedStakeDoc.publicKey = bytes32(_slice(stakeDoc, offset, offset + 32));

        // 'epoch_start' is an encoded integer
        (uint256 data, uint256 dataSize) = _decodeInteger(stakeDoc, offset + 32);
        decodedStakeDoc.epochStart = data;
        offset += 32 + dataSize;

        // 'epoch_post_end' is an encoded integer
        (data,  dataSize) = _decodeInteger(stakeDoc, offset);
        decodedStakeDoc.epochPostEnd = data;
        offset += dataSize;

        // 'syms_staked' is an encoded integer
        (data, dataSize) = _decodeInteger(stakeDoc, offset);
        decodedStakeDoc.symsStaked = data;
        offset += dataSize;

        return (decodedStakeDoc, offset);
    }

    /**
    * @notice Decodes a Themelio header.
    *
    * @dev Decodes the relevant attributes of a serialized Themelio header.
    *
    * @param header_ A serialized Themelio block header.
    *
    * @return The block height, transactions hash, and stakes hash of the header.
    */
    function _decodeHeader(bytes calldata header_)
        internal pure returns(uint256, bytes32, bytes32) {
        // using an offset of 33 to skip 'network' (1 byte) and 'previous' (32 bytes)
        uint256 offset = 33;

        (uint256 blockHeight, uint256 blockHeightSize) = _decodeInteger(header_, offset);

        // we can get the offset of 'transactions_hash' by adding `blockHeightSize` + 64 to skip
        // 'history_hash' (32 bytes) and 'coins_hash' (32 bytes)
        offset += blockHeightSize + 64;

        bytes32 transactionsHash = bytes32(_slice(header_, offset, offset + 32));

        bytes32 stakesHash = bytes32(_slice(header_, header_.length - 32, header_.length));

        return (blockHeight, transactionsHash, stakesHash);
    }

    /**
    * @notice Extracts and decodes the value and recipient of a Themelio bridge transaction.
    *
    * @dev Extracts and decodes 'value' and 'additional_data' fields in the first CoinData struct
    *      in the 'outputs' array of a bincode serialized themelio_structs::Transaction struct.
    *
    * @param transaction_ A serialized Themelio transaction.
    *
    * @return value The 'value' field in the first output of a Themelio transaction.
    *
    * @return recipient The 'additional_data' field in the first output of a Themelio transaction.
    */
    function _decodeTransaction(
        bytes calldata transaction_
    ) internal pure returns (bytes32, uint256, uint256, address) {
        // skip 'kind' enum (1 byte)
        uint256 offset = 1;

        // get 'inputs' array length and add its size to 'offset'
        (uint256 inputsLength, uint256 inputsLengthSize) = _decodeInteger(transaction_, offset);
        offset += inputsLengthSize;

        // aggregate size of each CoinData which is one hash (32 bytes) and one u8 integer (1 byte)
        offset += 33 * inputsLength;

        // get the size of the 'outputs' array's length and add to offset
        (,uint256 outputsLengthSize) = _decodeInteger(transaction_, offset);
        offset += outputsLengthSize;

        // add 'covhash' size to offset (32 bytes)
        bytes32 covhash = bytes32(_slice(transaction_, offset, offset + 32));
        offset += 32;

        // decode 'value' and add its size to 'offset'
        (uint256 value, uint256 valueSize) = _decodeInteger(transaction_, offset);
        offset += valueSize;

        // here we need to check the size of 'denom' because it can be 0, 1, or 32 bytes
        (uint256 denomSize, uint256 denomSizeLength) = _decodeInteger(transaction_, offset);
        offset += denomSizeLength; // the size of `denomSize`; the denom metasize, if you will.

        uint256 denom;

        if (denomSize == 1) {
            uint256 coin = uint8(bytes1(transaction_[offset:offset + 1]));

            if (coin == 0x64) {
                denom = ERG;
            } else if (coin == 0x6d) {
                denom = MEL;
            } else if (coin == 0x73) {
                denom = SYM;
            } else {
                assert(false);
            }
        } else if (denomSize == 32) {
            denom = uint256(bytes32(transaction_[offset:offset + 64]));
        } else {
            assert(false);
        }

        // 'denom' size to 'offset'
        offset += denomSize;

        // get size of 'additional_data' array's length, _extract recipient address from first item
        (,uint256 additionalDataLength) = _decodeInteger(transaction_, offset);
        offset += additionalDataLength;

        address recipient = address(bytes20(transaction_[offset:offset + 20]));

        return (covhash, value, denom, recipient);
    }

    /**
    * @notice Computes the a Merkle root given a hash and a Merkle proof.
    *
    * @dev Hashes a transaction's hash together with each hash in a Merkle proof in order to
    *      derive a Merkle root.
    *
    * @param leaf_ The leaf for which we are performing the proof of inclusion.
    *
    * @param index The index of the leaf in the Merkle tree. This is used to determine whether
    *        the 'tx_hash' should be concatenated on the left or the right before hashing.
    *
    * @param proof_ An array of blake3 hashes which together form the Merkle proof for this
    *        particular Themelio transaction.
    *
    * @return The Merkle root obtained by hashing 'tx_hash' together with each hash in 'proof' in
    *         sequence.
    */
    function _computeMerkleRoot(
        bytes32 leaf_,
        uint256 index,
        bytes32[] calldata proof_
    ) internal pure returns (bytes32) {
        bytes32 root = leaf_;
        bytes memory nodes;

        uint256 proofLength = proof_.length;

        for (uint256 i = 0; i < proofLength; ++i) {
            if (index % 2 == 0) {
                nodes = abi.encodePacked(root, proof_[i]);
            } else {
                nodes = abi.encodePacked(proof_[i], root);
            }

            index /= 2;
            root = _hashNodes(nodes);
        }

        return root;
    }

    /**
    * @notice This function reverts if msg.sender is not authorized to upgrade the contract.
    *
    * @dev This function is called by `upgradeTo()` and `upgradeToAndCall()` to authorize an
    *      upgrade.
    */
    function _authorizeUpgrade(address) internal override view onlyOwner {}
}
