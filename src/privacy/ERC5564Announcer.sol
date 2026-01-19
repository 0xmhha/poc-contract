// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @title IERC5564Announcer
 * @notice Interface for ERC-5564 Stealth Address announcements
 */
interface IERC5564Announcer {
    /// @notice Emitted when something is sent to a stealth address
    /// @param schemeId Identifier for the stealth address scheme (1 = secp256k1)
    /// @param stealthAddress The computed stealth address for the recipient
    /// @param caller The address that called the announce function
    /// @param ephemeralPubKey Ephemeral public key used to derive the stealth address
    /// @param metadata Additional data (first byte MUST be the view tag)
    event Announcement(
        uint256 indexed schemeId,
        address indexed stealthAddress,
        address indexed caller,
        bytes ephemeralPubKey,
        bytes metadata
    );

    /// @notice Emit an announcement for a stealth address transaction
    function announce(
        uint256 schemeId,
        address stealthAddress,
        bytes memory ephemeralPubKey,
        bytes memory metadata
    ) external;
}

/**
 * @title ERC5564Announcer
 * @notice Implementation of ERC-5564 Stealth Address announcements
 * @dev Emits events to broadcast information about stealth address transactions
 *      Recipients scan these events to detect payments sent to their stealth addresses
 *
 * Scheme IDs:
 *   - 1: secp256k1 (Ethereum default)
 *   - 2: secp256r1 (P-256, WebAuthn compatible)
 *
 * Metadata format:
 *   - First byte: View tag (for efficient scanning)
 *   - Remaining bytes: Application-specific data
 */
contract ERC5564Announcer is IERC5564Announcer {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidStealthAddress();
    error InvalidEphemeralPubKey();
    error UnsupportedScheme(uint256 schemeId);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new scheme is registered
    event SchemeRegistered(uint256 indexed schemeId, string description);

    /// @notice Emitted for batch announcements
    event BatchAnnouncement(
        uint256 indexed schemeId,
        address indexed caller,
        uint256 count
    );

    /*//////////////////////////////////////////////////////////////
                              STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Supported stealth address schemes
    mapping(uint256 => bool) public supportedSchemes;

    /// @notice Total number of announcements
    uint256 public totalAnnouncements;

    /// @notice Announcements per scheme
    mapping(uint256 => uint256) public announcementsByScheme;

    /// @notice Whether to enforce scheme validation
    bool public enforceSchemeValidation;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        // Register default schemes
        supportedSchemes[1] = true; // secp256k1
        supportedSchemes[2] = true; // secp256r1 (P-256)

        emit SchemeRegistered(1, "secp256k1");
        emit SchemeRegistered(2, "secp256r1");
    }

    /*//////////////////////////////////////////////////////////////
                           CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emit an announcement for a stealth address transaction
     * @param schemeId Identifier for the stealth address scheme
     * @param stealthAddress The computed stealth address
     * @param ephemeralPubKey Ephemeral public key used by sender
     * @param metadata Additional data (first byte = view tag)
     */
    function announce(
        uint256 schemeId,
        address stealthAddress,
        bytes memory ephemeralPubKey,
        bytes memory metadata
    ) external override {
        // Validate inputs
        if (stealthAddress == address(0)) revert InvalidStealthAddress();
        if (ephemeralPubKey.length == 0) revert InvalidEphemeralPubKey();

        // Optional scheme validation
        if (enforceSchemeValidation && !supportedSchemes[schemeId]) {
            revert UnsupportedScheme(schemeId);
        }

        // Update counters
        unchecked {
            totalAnnouncements++;
            announcementsByScheme[schemeId]++;
        }

        // Emit the announcement
        emit Announcement(schemeId, stealthAddress, msg.sender, ephemeralPubKey, metadata);
    }

    /**
     * @notice Emit multiple announcements in a single transaction
     * @param schemeId Identifier for the stealth address scheme
     * @param stealthAddresses Array of stealth addresses
     * @param ephemeralPubKeys Array of ephemeral public keys
     * @param metadatas Array of metadata
     */
    function announceBatch(
        uint256 schemeId,
        address[] calldata stealthAddresses,
        bytes[] calldata ephemeralPubKeys,
        bytes[] calldata metadatas
    ) external {
        uint256 length = stealthAddresses.length;

        require(
            length == ephemeralPubKeys.length && length == metadatas.length,
            "Array length mismatch"
        );

        // Optional scheme validation
        if (enforceSchemeValidation && !supportedSchemes[schemeId]) {
            revert UnsupportedScheme(schemeId);
        }

        for (uint256 i = 0; i < length; ) {
            if (stealthAddresses[i] == address(0)) revert InvalidStealthAddress();
            if (ephemeralPubKeys[i].length == 0) revert InvalidEphemeralPubKey();

            emit Announcement(
                schemeId,
                stealthAddresses[i],
                msg.sender,
                ephemeralPubKeys[i],
                metadatas[i]
            );

            unchecked { i++; }
        }

        // Update counters
        unchecked {
            totalAnnouncements += length;
            announcementsByScheme[schemeId] += length;
        }

        emit BatchAnnouncement(schemeId, msg.sender, length);
    }

    /**
     * @notice Announce with native token transfer
     * @dev Sends native tokens to the stealth address and emits announcement
     * @param schemeId Identifier for the stealth address scheme
     * @param stealthAddress The computed stealth address
     * @param ephemeralPubKey Ephemeral public key used by sender
     * @param metadata Additional data (first byte = view tag)
     */
    function announceAndTransfer(
        uint256 schemeId,
        address stealthAddress,
        bytes memory ephemeralPubKey,
        bytes memory metadata
    ) external payable {
        // Validate inputs
        if (stealthAddress == address(0)) revert InvalidStealthAddress();
        if (ephemeralPubKey.length == 0) revert InvalidEphemeralPubKey();

        // Transfer native tokens
        if (msg.value > 0) {
            (bool success, ) = stealthAddress.call{value: msg.value}("");
            require(success, "Native transfer failed");
        }

        // Update counters
        unchecked {
            totalAnnouncements++;
            announcementsByScheme[schemeId]++;
        }

        // Emit the announcement
        emit Announcement(schemeId, stealthAddress, msg.sender, ephemeralPubKey, metadata);
    }

    /*//////////////////////////////////////////////////////////////
                           VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Check if a scheme is supported
     * @param schemeId The scheme identifier
     * @return Whether the scheme is supported
     */
    function isSchemeSupported(uint256 schemeId) external view returns (bool) {
        return supportedSchemes[schemeId];
    }

    /**
     * @notice Get announcement statistics
     * @return total Total announcements
     * @return secp256k1Count Announcements using secp256k1
     * @return secp256r1Count Announcements using secp256r1
     */
    function getStats() external view returns (
        uint256 total,
        uint256 secp256k1Count,
        uint256 secp256r1Count
    ) {
        return (
            totalAnnouncements,
            announcementsByScheme[1],
            announcementsByScheme[2]
        );
    }

    /*//////////////////////////////////////////////////////////////
                           HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Generate view tag from stealth address
     * @dev View tag is used for efficient scanning
     * @param stealthAddress The stealth address
     * @return viewTag The first byte used as view tag
     */
    function generateViewTag(address stealthAddress) external pure returns (bytes1) {
        // Casting to uint8 is safe: after >> 152, only 8 bits remain (160 - 152 = 8)
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes1(uint8(uint160(stealthAddress) >> 152));
    }

    /**
     * @notice Encode metadata with view tag
     * @param viewTag The view tag byte
     * @param data Additional metadata
     * @return metadata Encoded metadata with view tag as first byte
     */
    function encodeMetadata(
        bytes1 viewTag,
        bytes calldata data
    ) external pure returns (bytes memory metadata) {
        metadata = abi.encodePacked(viewTag, data);
    }
}
