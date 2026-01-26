// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title IERC1271
 * @notice Interface for EIP-1271 signature validation
 */
interface IERC1271 {
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4 magicValue);
}

/**
 * @title IERC6538Registry
 * @notice Interface for ERC-6538 Stealth Meta-Address Registry
 */
interface IERC6538Registry {
    error ERC6538Registry__InvalidSignature();

    event StealthMetaAddressSet(address indexed registrant, uint256 indexed schemeId, bytes stealthMetaAddress);

    event NonceIncremented(address indexed registrant, uint256 newNonce);

    function registerKeys(uint256 schemeId, bytes calldata stealthMetaAddress) external;

    function registerKeysOnBehalf(
        address registrant,
        uint256 schemeId,
        bytes memory signature,
        bytes calldata stealthMetaAddress
    ) external;

    function incrementNonce() external;

    function DOMAIN_SEPARATOR() external view returns (bytes32);

    function stealthMetaAddressOf(address registrant, uint256 schemeId) external view returns (bytes memory);

    function ERC6538REGISTRY_ENTRY_TYPE_HASH() external view returns (bytes32);

    function nonceOf(address registrant) external view returns (uint256);
}

/**
 * @title ERC6538Registry
 * @notice Registry for stealth meta-addresses as defined in ERC-6538
 * @dev Maps accounts to their stealth meta-addresses for each scheme ID
 *
 * Stealth Meta-Address Format (ERC-5564):
 *   st:<chainShortName>:0x<spendingPubKey>:<viewingPubKey>
 *
 * On-chain storage:
 *   Just the concatenated spendingPubKey + viewingPubKey (chain is implicit)
 *
 * Supported registration methods:
 *   1. Direct: registerKeys() - caller registers their own keys
 *   2. On-behalf: registerKeysOnBehalf() - register for another with signature
 */
contract ERC6538Registry is IERC6538Registry {
    using ECDSA for bytes32;

    /* //////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidStealthMetaAddress();
    error KeysNotRegistered();

    /* //////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when keys are removed
    event StealthMetaAddressRemoved(address indexed registrant, uint256 indexed schemeId);

    /* //////////////////////////////////////////////////////////////
                              STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Mapping of registrant => schemeId => stealth meta-address
    mapping(address registrant => mapping(uint256 schemeId => bytes)) public stealthMetaAddressOf;

    /// @notice Nonce for each registrant (for signature replay protection)
    mapping(address registrant => uint256) public nonceOf;

    /// @notice EIP-712 type hash for registration entries
    bytes32 public constant ERC6538REGISTRY_ENTRY_TYPE_HASH =
        keccak256("Erc6538RegistryEntry(uint256 schemeId,bytes stealthMetaAddress,uint256 nonce)");

    /// @notice Chain ID at deployment (for domain separator)
    uint256 internal immutable INITIAL_CHAIN_ID;

    /// @notice Domain separator at deployment
    bytes32 internal immutable INITIAL_DOMAIN_SEPARATOR;

    /// @notice EIP-1271 magic value for valid signatures
    bytes4 internal constant EIP1271_MAGIC_VALUE = 0_x16_26b_a7e;

    /* //////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        INITIAL_CHAIN_ID = block.chainid;
        INITIAL_DOMAIN_SEPARATOR = _computeDomainSeparator();
    }

    /* //////////////////////////////////////////////////////////////
                        REGISTRATION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Register stealth meta-address for the caller
     * @param schemeId Identifier for the stealth address scheme
     * @param stealthMetaAddress The stealth meta-address (spending + viewing public keys)
     */
    function registerKeys(uint256 schemeId, bytes calldata stealthMetaAddress) external override {
        if (stealthMetaAddress.length == 0) revert InvalidStealthMetaAddress();

        stealthMetaAddressOf[msg.sender][schemeId] = stealthMetaAddress;
        emit StealthMetaAddressSet(msg.sender, schemeId, stealthMetaAddress);
    }

    /**
     * @notice Register stealth meta-address on behalf of another account
     * @param registrant The account to register for
     * @param schemeId Identifier for the stealth address scheme
     * @param signature EIP-712 signature from the registrant
     * @param stealthMetaAddress The stealth meta-address
     * @dev Supports both EOA (ECDSA) and smart contract (EIP-1271) signatures
     */
    function registerKeysOnBehalf(
        address registrant,
        uint256 schemeId,
        bytes memory signature,
        bytes calldata stealthMetaAddress
    ) external override {
        if (stealthMetaAddress.length == 0) revert InvalidStealthMetaAddress();

        // Build the EIP-712 digest
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 structHash = keccak256(
            abi.encode(ERC6538REGISTRY_ENTRY_TYPE_HASH, schemeId, keccak256(stealthMetaAddress), nonceOf[registrant])
        );

        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));

        // Increment nonce before validation (prevents replay)
        unchecked {
            nonceOf[registrant]++;
        }

        // Validate signature
        bool isValidSignature = false;

        // Try ECDSA recovery first (for EOAs)
        if (signature.length == 65) {
            address recovered = digest.recover(signature);
            if (recovered == registrant && recovered != address(0)) {
                isValidSignature = true;
            }
        }

        // If ECDSA failed and registrant is a contract, try EIP-1271
        if (!isValidSignature && registrant.code.length > 0) {
            try IERC1271(registrant).isValidSignature(digest, signature) returns (bytes4 magicValue) {
                isValidSignature = (magicValue == EIP1271_MAGIC_VALUE);
            } catch {
                // Contract doesn't support EIP-1271 or call failed
            }
        }

        if (!isValidSignature) revert ERC6538Registry__InvalidSignature();

        // Store the stealth meta-address
        stealthMetaAddressOf[registrant][schemeId] = stealthMetaAddress;
        emit StealthMetaAddressSet(registrant, schemeId, stealthMetaAddress);
    }

    /**
     * @notice Remove stealth meta-address for the caller
     * @param schemeId Identifier for the stealth address scheme
     */
    function removeKeys(uint256 schemeId) external {
        if (stealthMetaAddressOf[msg.sender][schemeId].length == 0) {
            revert KeysNotRegistered();
        }

        delete stealthMetaAddressOf[msg.sender][schemeId];
        emit StealthMetaAddressRemoved(msg.sender, schemeId);
    }

    /**
     * @notice Increment caller's nonce to invalidate existing signatures
     */
    function incrementNonce() external override {
        unchecked {
            nonceOf[msg.sender]++;
        }
        emit NonceIncremented(msg.sender, nonceOf[msg.sender]);
    }

    /* //////////////////////////////////////////////////////////////
                           VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the EIP-712 domain separator
     * @return The domain separator (recomputed if chain forked)
     */
    // Function name follows EIP-712 standard
    // forge-lint: disable-next-line(mixed-case-function)
    function DOMAIN_SEPARATOR() public view override returns (bytes32) {
        return block.chainid == INITIAL_CHAIN_ID ? INITIAL_DOMAIN_SEPARATOR : _computeDomainSeparator();
    }

    /**
     * @notice Check if an account has registered keys for a scheme
     * @param registrant The account to check
     * @param schemeId The scheme identifier
     * @return Whether keys are registered
     */
    function hasRegisteredKeys(address registrant, uint256 schemeId) external view returns (bool) {
        return stealthMetaAddressOf[registrant][schemeId].length > 0;
    }

    /**
     * @notice Get the stealth meta-address for a registrant
     * @param registrant The account
     * @param schemeId The scheme identifier
     * @return The stealth meta-address bytes
     */
    function getStealthMetaAddress(address registrant, uint256 schemeId) external view returns (bytes memory) {
        bytes memory metaAddress = stealthMetaAddressOf[registrant][schemeId];
        if (metaAddress.length == 0) revert KeysNotRegistered();
        return metaAddress;
    }

    /**
     * @notice Parse stealth meta-address into spending and viewing keys
     * @param stealthMetaAddress The raw stealth meta-address bytes
     * @return spendingPubKey The spending public key (33 bytes compressed)
     * @return viewingPubKey The viewing public key (33 bytes compressed)
     * @dev Assumes compressed public keys (33 bytes each)
     */
    function parseStealthMetaAddress(bytes calldata stealthMetaAddress)
        external
        pure
        returns (bytes memory spendingPubKey, bytes memory viewingPubKey)
    {
        require(stealthMetaAddress.length >= 66, "Invalid stealth meta-address length");

        spendingPubKey = stealthMetaAddress[:33];
        viewingPubKey = stealthMetaAddress[33:66];
    }

    /* //////////////////////////////////////////////////////////////
                         INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Compute the EIP-712 domain separator
     */
    function _computeDomainSeparator() internal view returns (bytes32) {
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("ERC6538Registry"),
                keccak256("1.0"),
                block.chainid,
                address(this)
            )
        );
    }
}
