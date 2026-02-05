// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MerchantRegistry
 * @notice Registry for merchant registration, verification, and fee management
 * @dev Works with SubscriptionManager to restrict plan creation to verified merchants
 *
 * Features:
 * - Merchant registration with metadata
 * - Verification by authorized verifiers
 * - Configurable fee rates per merchant
 * - Suspension functionality
 * - Verifier role management
 *
 * Flow:
 * 1. Merchant registers with business info
 * 2. Verifier reviews and verifies merchant
 * 3. Admin can set custom fee rates
 * 4. Verified merchants can create subscription plans
 */
contract MerchantRegistry is Ownable {
    // ============ Structs ============

    /// @notice Merchant information
    struct Merchant {
        string name;
        string website;
        string email;
        bool isRegistered;
        bool isVerified;
        bool isSuspended;
        uint256 registeredAt;
        uint256 verifiedAt;
        address verifiedBy;
        uint256 customFeeBps; // 0 means use default
    }

    // ============ State Variables ============

    /// @notice Default fee in basis points (2.5%)
    uint256 public constant DEFAULT_FEE_BPS = 250;

    /// @notice Maximum fee in basis points (10%)
    uint256 public constant MAX_FEE_BPS = 1000;

    /// @notice Merchant address => Merchant info
    mapping(address => Merchant) public merchants;

    /// @notice Verifier address => is verifier
    mapping(address => bool) public verifiers;

    /// @notice List of all registered merchants
    address[] public merchantList;

    /// @notice List of verified merchants
    address[] public verifiedMerchantList;

    /// @notice List of verifiers
    address[] public verifierList;

    // ============ Events ============

    event MerchantRegistered(address indexed merchant, string name);
    event MerchantUpdated(address indexed merchant, string name);
    event MerchantVerified(address indexed merchant, address indexed verifier);
    event VerificationRevoked(address indexed merchant, address indexed revoker);
    event MerchantSuspended(address indexed merchant);
    event MerchantUnsuspended(address indexed merchant);
    event MerchantFeeUpdated(address indexed merchant, uint256 feeBps);
    event VerifierAdded(address indexed verifier);
    event VerifierRemoved(address indexed verifier);

    // ============ Errors ============

    error AlreadyRegistered();
    error NotRegistered();
    error AlreadyVerified();
    error NotVerified();
    error NotVerifier();
    error AlreadyVerifier();
    error InvalidMerchantData();
    error InvalidAddress();
    error FeeTooHigh();
    error AlreadySuspended();
    error NotSuspended();

    // ============ Constructor ============

    constructor() Ownable(msg.sender) {}

    // ============ Registration Functions ============

    /**
     * @notice Register as a merchant
     * @param name Business name
     * @param website Business website URL
     * @param email Contact email
     */
    function registerMerchant(
        string calldata name,
        string calldata website,
        string calldata email
    ) external {
        if (merchants[msg.sender].isRegistered) {
            revert AlreadyRegistered();
        }

        if (bytes(name).length == 0) {
            revert InvalidMerchantData();
        }

        merchants[msg.sender] = Merchant({
            name: name,
            website: website,
            email: email,
            isRegistered: true,
            isVerified: false,
            isSuspended: false,
            registeredAt: block.timestamp,
            verifiedAt: 0,
            verifiedBy: address(0),
            customFeeBps: 0
        });

        merchantList.push(msg.sender);

        emit MerchantRegistered(msg.sender, name);
    }

    /**
     * @notice Update merchant information
     * @param name New business name
     * @param website New website URL
     * @param email New contact email
     */
    function updateMerchantInfo(
        string calldata name,
        string calldata website,
        string calldata email
    ) external {
        Merchant storage merchant = merchants[msg.sender];

        if (!merchant.isRegistered) {
            revert NotRegistered();
        }

        if (bytes(name).length == 0) {
            revert InvalidMerchantData();
        }

        merchant.name = name;
        merchant.website = website;
        merchant.email = email;

        emit MerchantUpdated(msg.sender, name);
    }

    // ============ Verification Functions ============

    /**
     * @notice Verify a merchant (verifier only)
     * @param merchant Merchant address to verify
     */
    function verifyMerchant(address merchant) external {
        if (!verifiers[msg.sender]) {
            revert NotVerifier();
        }

        Merchant storage m = merchants[merchant];

        if (!m.isRegistered) {
            revert NotRegistered();
        }

        if (m.isVerified) {
            revert AlreadyVerified();
        }

        m.isVerified = true;
        m.verifiedAt = block.timestamp;
        m.verifiedBy = msg.sender;

        verifiedMerchantList.push(merchant);

        emit MerchantVerified(merchant, msg.sender);
    }

    /**
     * @notice Revoke merchant verification (verifier only)
     * @param merchant Merchant address
     */
    function revokeVerification(address merchant) external {
        if (!verifiers[msg.sender]) {
            revert NotVerifier();
        }

        Merchant storage m = merchants[merchant];

        if (!m.isVerified) {
            revert NotVerified();
        }

        m.isVerified = false;
        m.verifiedAt = 0;
        m.verifiedBy = address(0);

        _removeFromVerifiedList(merchant);

        emit VerificationRevoked(merchant, msg.sender);
    }

    // ============ Suspension Functions ============

    /**
     * @notice Suspend a merchant (owner only)
     * @param merchant Merchant address to suspend
     */
    function suspendMerchant(address merchant) external onlyOwner {
        Merchant storage m = merchants[merchant];

        if (!m.isRegistered) {
            revert NotRegistered();
        }

        if (m.isSuspended) {
            revert AlreadySuspended();
        }

        m.isSuspended = true;

        emit MerchantSuspended(merchant);
    }

    /**
     * @notice Unsuspend a merchant (owner only)
     * @param merchant Merchant address to unsuspend
     */
    function unsuspendMerchant(address merchant) external onlyOwner {
        Merchant storage m = merchants[merchant];

        if (!m.isSuspended) {
            revert NotSuspended();
        }

        m.isSuspended = false;

        emit MerchantUnsuspended(merchant);
    }

    // ============ Fee Management ============

    /**
     * @notice Set custom fee rate for a merchant (owner only)
     * @param merchant Merchant address
     * @param feeBps Fee in basis points
     */
    function setMerchantFee(address merchant, uint256 feeBps) external onlyOwner {
        if (feeBps > MAX_FEE_BPS) {
            revert FeeTooHigh();
        }

        merchants[merchant].customFeeBps = feeBps;

        emit MerchantFeeUpdated(merchant, feeBps);
    }

    /**
     * @notice Get merchant's fee rate
     * @param merchant Merchant address
     * @return Fee in basis points
     */
    function getMerchantFee(address merchant) external view returns (uint256) {
        uint256 customFee = merchants[merchant].customFeeBps;
        return customFee > 0 ? customFee : DEFAULT_FEE_BPS;
    }

    // ============ Verifier Management ============

    /**
     * @notice Add a verifier (owner only)
     * @param verifier Address to add as verifier
     */
    function addVerifier(address verifier) external onlyOwner {
        if (verifier == address(0)) {
            revert InvalidAddress();
        }

        if (verifiers[verifier]) {
            revert AlreadyVerifier();
        }

        verifiers[verifier] = true;
        verifierList.push(verifier);

        emit VerifierAdded(verifier);
    }

    /**
     * @notice Remove a verifier (owner only)
     * @param verifier Address to remove
     */
    function removeVerifier(address verifier) external onlyOwner {
        if (!verifiers[verifier]) {
            revert NotVerifier();
        }

        verifiers[verifier] = false;
        _removeFromVerifierList(verifier);

        emit VerifierRemoved(verifier);
    }

    // ============ View Functions ============

    /**
     * @notice Check if an address is a registered merchant
     * @param merchant Address to check
     */
    function isMerchantRegistered(address merchant) external view returns (bool) {
        return merchants[merchant].isRegistered;
    }

    /**
     * @notice Check if a merchant is verified
     * @param merchant Address to check
     */
    function isMerchantVerified(address merchant) external view returns (bool) {
        return merchants[merchant].isVerified;
    }

    /**
     * @notice Check if a merchant is suspended
     * @param merchant Address to check
     */
    function isMerchantSuspended(address merchant) external view returns (bool) {
        return merchants[merchant].isSuspended;
    }

    /**
     * @notice Check if a merchant is active (verified and not suspended)
     * @param merchant Address to check
     */
    function isMerchantActive(address merchant) external view returns (bool) {
        Merchant storage m = merchants[merchant];
        return m.isVerified && !m.isSuspended;
    }

    /**
     * @notice Check if an address is a verifier
     * @param verifier Address to check
     */
    function isVerifier(address verifier) external view returns (bool) {
        return verifiers[verifier];
    }

    /**
     * @notice Get merchant information
     * @param merchant Merchant address
     * @return name Business name
     * @return website Website URL
     * @return email Contact email
     * @return isVerified Verification status
     * @return isSuspended Suspension status
     * @return registeredAt Registration timestamp
     */
    function getMerchantInfo(address merchant) external view returns (
        string memory name,
        string memory website,
        string memory email,
        bool isVerified,
        bool isSuspended,
        uint256 registeredAt
    ) {
        Merchant storage m = merchants[merchant];
        return (
            m.name,
            m.website,
            m.email,
            m.isVerified,
            m.isSuspended,
            m.registeredAt
        );
    }

    /**
     * @notice Get list of all verified merchants
     */
    function getVerifiedMerchants() external view returns (address[] memory) {
        return verifiedMerchantList;
    }

    /**
     * @notice Get total number of registered merchants
     */
    function getTotalMerchants() external view returns (uint256) {
        return merchantList.length;
    }

    /**
     * @notice Get list of all verifiers
     */
    function getVerifiers() external view returns (address[] memory) {
        return verifierList;
    }

    // ============ Internal Functions ============

    /**
     * @notice Remove merchant from verified list
     */
    function _removeFromVerifiedList(address merchant) internal {
        uint256 length = verifiedMerchantList.length;
        for (uint256 i = 0; i < length; i++) {
            if (verifiedMerchantList[i] == merchant) {
                verifiedMerchantList[i] = verifiedMerchantList[length - 1];
                verifiedMerchantList.pop();
                break;
            }
        }
    }

    /**
     * @notice Remove verifier from list
     */
    function _removeFromVerifierList(address verifier) internal {
        uint256 length = verifierList.length;
        for (uint256 i = 0; i < length; i++) {
            if (verifierList[i] == verifier) {
                verifierList[i] = verifierList[length - 1];
                verifierList.pop();
                break;
            }
        }
    }
}
