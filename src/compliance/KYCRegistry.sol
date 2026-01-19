// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title KYCRegistry
 * @notice Manages on-chain KYC status, risk levels, and sanctions screening
 * @dev Implements allow/block list management with multi-jurisdiction support
 *
 * Key Features:
 *   - KYC status tracking (NONE, PENDING, VERIFIED, REJECTED, EXPIRED)
 *   - Risk level categorization (LOW, MEDIUM, HIGH, PROHIBITED)
 *   - Sanctions list integration (OFAC, UN, EU compatible)
 *   - Multi-jurisdiction support
 *   - KYC provider hash tracking for audit
 */
contract KYCRegistry is AccessControl, Pausable, ReentrancyGuard {
    // ============ Roles ============
    bytes32 public constant KYC_ADMIN_ROLE = keccak256("KYC_ADMIN_ROLE");
    bytes32 public constant SANCTIONS_ADMIN_ROLE = keccak256("SANCTIONS_ADMIN_ROLE");
    bytes32 public constant KYC_PROVIDER_ROLE = keccak256("KYC_PROVIDER_ROLE");

    // ============ Constants ============
    uint256 public constant DEFAULT_KYC_VALIDITY = 365 days;
    uint256 public constant MAX_KYC_VALIDITY = 730 days; // 2 years
    uint256 public constant MIN_KYC_VALIDITY = 30 days;

    // ============ Enums ============
    enum KYCStatus {
        NONE,      // 0 - Not started
        PENDING,   // 1 - In progress
        VERIFIED,  // 2 - Approved
        REJECTED,  // 3 - Denied
        EXPIRED    // 4 - Was verified but expired
    }

    enum RiskLevel {
        LOW,        // 0 - Standard users
        MEDIUM,     // 1 - Enhanced monitoring
        HIGH,       // 2 - Restricted operations
        PROHIBITED  // 3 - Blocked (sanctions)
    }

    enum SanctionsList {
        NONE,   // 0 - Not on any list
        OFAC,   // 1 - US OFAC
        UN,     // 2 - UN Security Council
        EU,     // 3 - European Union
        OTHER   // 4 - Other jurisdiction
    }

    // ============ Structs ============
    struct KycRecord {
        KYCStatus status;
        RiskLevel riskLevel;
        uint256 verifiedAt;
        uint256 expiresAt;
        bytes32 kycProviderHash;    // Hash of KYC provider identifier
        bytes32 kycDataHash;        // Hash of KYC data for verification
        string jurisdiction;
        uint256 lastUpdated;
        address updatedBy;
    }

    struct SanctionsRecord {
        bool isSanctioned;
        SanctionsList listType;
        uint256 addedAt;
        bytes32 sanctionId;         // External reference ID
        string reason;
    }

    struct KycProvider {
        string name;
        string jurisdiction;
        bool isActive;
        uint256 registeredAt;
        uint256 verificationsCount;
    }

    // ============ State Variables ============
    mapping(address => KycRecord) public kycRecords;
    mapping(address => SanctionsRecord) public sanctionsRecords;
    mapping(address => KycProvider) public kycProviders;

    // Allow/Block lists
    mapping(address => bool) public allowList;
    mapping(address => bool) public blockList;

    // Jurisdiction settings
    mapping(string => uint256) public jurisdictionKycValidity;
    mapping(string => RiskLevel) public jurisdictionDefaultRisk;

    uint256 public totalVerified;
    uint256 public totalSanctioned;
    uint256 public defaultKycValidity;

    // ============ Events ============
    event KYCStatusUpdated(
        address indexed account,
        KYCStatus oldStatus,
        KYCStatus newStatus,
        address indexed updatedBy
    );
    event KYCVerified(
        address indexed account,
        bytes32 kycProviderHash,
        string jurisdiction,
        uint256 expiresAt
    );
    event KYCRejected(
        address indexed account,
        string reason,
        address indexed rejectedBy
    );
    event KYCExpired(address indexed account);
    event RiskLevelUpdated(
        address indexed account,
        RiskLevel oldLevel,
        RiskLevel newLevel
    );

    event SanctionsAdded(
        address indexed account,
        SanctionsList listType,
        bytes32 sanctionId,
        string reason
    );
    event SanctionsRemoved(
        address indexed account,
        SanctionsList listType,
        string reason
    );

    event AddedToAllowList(address indexed account);
    event RemovedFromAllowList(address indexed account);
    event AddedToBlockList(address indexed account, string reason);
    event RemovedFromBlockList(address indexed account);

    event KycProviderRegistered(
        address indexed provider,
        string name,
        string jurisdiction
    );
    event KycProviderDeactivated(address indexed provider);

    event JurisdictionConfigured(
        string jurisdiction,
        uint256 kycValidity,
        RiskLevel defaultRisk
    );

    // ============ Errors ============
    error InvalidAddress();
    error InvalidStatus();
    error InvalidRiskLevel();
    error InvalidValidity();
    error InvalidJurisdiction();
    error AccountSanctioned();
    error AccountBlocked();
    error KYCNotVerified();
    error KYCAlreadyVerified();
    error KYCExpiredError();
    error ProviderNotActive();
    error ProviderAlreadyExists();
    error ProviderNotFound();
    error EmptyName();
    error NotAuthorized();

    // ============ Constructor ============
    constructor(address admin) {
        if (admin == address(0)) revert InvalidAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(KYC_ADMIN_ROLE, admin);
        _grantRole(SANCTIONS_ADMIN_ROLE, admin);

        defaultKycValidity = DEFAULT_KYC_VALIDITY;
    }

    // ============ KYC Management ============

    /**
     * @notice Start KYC process for an account
     * @param account Address to start KYC for
     */
    function initiateKyc(
        address account
    ) external onlyRole(KYC_ADMIN_ROLE) whenNotPaused {
        if (account == address(0)) revert InvalidAddress();
        if (sanctionsRecords[account].isSanctioned) revert AccountSanctioned();
        if (blockList[account]) revert AccountBlocked();

        KycRecord storage record = kycRecords[account];
        KYCStatus oldStatus = record.status;

        if (oldStatus == KYCStatus.VERIFIED && block.timestamp < record.expiresAt) {
            revert KYCAlreadyVerified();
        }

        record.status = KYCStatus.PENDING;
        record.lastUpdated = block.timestamp;
        record.updatedBy = msg.sender;

        emit KYCStatusUpdated(account, oldStatus, KYCStatus.PENDING, msg.sender);
    }

    /**
     * @notice Verify KYC for an account
     * @param account Address to verify
     * @param kycProviderHash Hash of KYC provider
     * @param kycDataHash Hash of KYC data
     * @param jurisdiction Jurisdiction code
     * @param riskLevel Risk level assignment
     * @param validityDays Custom validity period (0 for default)
     */
    function verifyKyc(
        address account,
        bytes32 kycProviderHash,
        bytes32 kycDataHash,
        string calldata jurisdiction,
        RiskLevel riskLevel,
        uint256 validityDays
    ) external onlyRole(KYC_PROVIDER_ROLE) whenNotPaused nonReentrant {
        if (account == address(0)) revert InvalidAddress();
        if (bytes(jurisdiction).length == 0) revert InvalidJurisdiction();
        if (sanctionsRecords[account].isSanctioned) revert AccountSanctioned();
        if (blockList[account]) revert AccountBlocked();
        if (riskLevel == RiskLevel.PROHIBITED) revert InvalidRiskLevel();

        // Determine validity period
        uint256 validity;
        if (validityDays > 0) {
            if (validityDays * 1 days < MIN_KYC_VALIDITY || validityDays * 1 days > MAX_KYC_VALIDITY) {
                revert InvalidValidity();
            }
            validity = validityDays * 1 days;
        } else if (jurisdictionKycValidity[jurisdiction] > 0) {
            validity = jurisdictionKycValidity[jurisdiction];
        } else {
            validity = defaultKycValidity;
        }

        KycRecord storage record = kycRecords[account];
        KYCStatus oldStatus = record.status;

        record.status = KYCStatus.VERIFIED;
        record.riskLevel = riskLevel;
        record.verifiedAt = block.timestamp;
        record.expiresAt = block.timestamp + validity;
        record.kycProviderHash = kycProviderHash;
        record.kycDataHash = kycDataHash;
        record.jurisdiction = jurisdiction;
        record.lastUpdated = block.timestamp;
        record.updatedBy = msg.sender;

        if (oldStatus != KYCStatus.VERIFIED) {
            totalVerified++;
        }

        // Update provider stats
        if (kycProviders[msg.sender].isActive) {
            kycProviders[msg.sender].verificationsCount++;
        }

        emit KYCStatusUpdated(account, oldStatus, KYCStatus.VERIFIED, msg.sender);
        emit KYCVerified(account, kycProviderHash, jurisdiction, record.expiresAt);
    }

    /**
     * @notice Reject KYC for an account
     * @param account Address to reject
     * @param reason Rejection reason
     */
    function rejectKyc(
        address account,
        string calldata reason
    ) external onlyRole(KYC_ADMIN_ROLE) whenNotPaused {
        if (account == address(0)) revert InvalidAddress();

        KycRecord storage record = kycRecords[account];
        KYCStatus oldStatus = record.status;

        record.status = KYCStatus.REJECTED;
        record.lastUpdated = block.timestamp;
        record.updatedBy = msg.sender;

        emit KYCStatusUpdated(account, oldStatus, KYCStatus.REJECTED, msg.sender);
        emit KYCRejected(account, reason, msg.sender);
    }

    /**
     * @notice Update risk level for an account
     * @param account Address to update
     * @param newLevel New risk level
     */
    function updateRiskLevel(
        address account,
        RiskLevel newLevel
    ) external onlyRole(KYC_ADMIN_ROLE) {
        if (account == address(0)) revert InvalidAddress();

        KycRecord storage record = kycRecords[account];
        RiskLevel oldLevel = record.riskLevel;

        record.riskLevel = newLevel;
        record.lastUpdated = block.timestamp;
        record.updatedBy = msg.sender;

        // If PROHIBITED, add to block list
        if (newLevel == RiskLevel.PROHIBITED) {
            blockList[account] = true;
            emit AddedToBlockList(account, "Risk level PROHIBITED");
        }

        emit RiskLevelUpdated(account, oldLevel, newLevel);
    }

    /**
     * @notice Manually expire KYC (for compliance reasons)
     * @param account Address to expire
     */
    function expireKyc(
        address account
    ) external onlyRole(KYC_ADMIN_ROLE) {
        KycRecord storage record = kycRecords[account];
        if (record.status != KYCStatus.VERIFIED) revert KYCNotVerified();

        KYCStatus oldStatus = record.status;
        record.status = KYCStatus.EXPIRED;
        record.lastUpdated = block.timestamp;
        record.updatedBy = msg.sender;

        totalVerified--;

        emit KYCStatusUpdated(account, oldStatus, KYCStatus.EXPIRED, msg.sender);
        emit KYCExpired(account);
    }

    // ============ Sanctions Management ============

    /**
     * @notice Add address to sanctions list
     * @param account Address to sanction
     * @param listType Type of sanctions list
     * @param sanctionId External reference ID
     * @param reason Reason for sanction
     */
    function addToSanctions(
        address account,
        SanctionsList listType,
        bytes32 sanctionId,
        string calldata reason
    ) external onlyRole(SANCTIONS_ADMIN_ROLE) {
        if (account == address(0)) revert InvalidAddress();
        if (listType == SanctionsList.NONE) revert InvalidStatus();

        sanctionsRecords[account] = SanctionsRecord({
            isSanctioned: true,
            listType: listType,
            addedAt: block.timestamp,
            sanctionId: sanctionId,
            reason: reason
        });

        // Also update KYC risk level
        kycRecords[account].riskLevel = RiskLevel.PROHIBITED;
        kycRecords[account].lastUpdated = block.timestamp;
        kycRecords[account].updatedBy = msg.sender;

        // Add to block list
        blockList[account] = true;

        totalSanctioned++;

        emit SanctionsAdded(account, listType, sanctionId, reason);
        emit RiskLevelUpdated(account, kycRecords[account].riskLevel, RiskLevel.PROHIBITED);
        emit AddedToBlockList(account, "Sanctions list");
    }

    /**
     * @notice Remove address from sanctions list
     * @param account Address to remove
     * @param reason Reason for removal
     */
    function removeFromSanctions(
        address account,
        string calldata reason
    ) external onlyRole(SANCTIONS_ADMIN_ROLE) {
        SanctionsRecord storage record = sanctionsRecords[account];
        if (!record.isSanctioned) revert InvalidStatus();

        SanctionsList oldListType = record.listType;

        record.isSanctioned = false;
        record.listType = SanctionsList.NONE;

        totalSanctioned--;

        emit SanctionsRemoved(account, oldListType, reason);
    }

    // ============ Allow/Block List Management ============

    /**
     * @notice Add address to allow list
     * @param account Address to add
     */
    function addToAllowList(
        address account
    ) external onlyRole(KYC_ADMIN_ROLE) {
        if (account == address(0)) revert InvalidAddress();
        if (sanctionsRecords[account].isSanctioned) revert AccountSanctioned();

        allowList[account] = true;
        emit AddedToAllowList(account);
    }

    /**
     * @notice Remove address from allow list
     * @param account Address to remove
     */
    function removeFromAllowList(
        address account
    ) external onlyRole(KYC_ADMIN_ROLE) {
        allowList[account] = false;
        emit RemovedFromAllowList(account);
    }

    /**
     * @notice Add address to block list
     * @param account Address to add
     * @param reason Reason for blocking
     */
    function addToBlockList(
        address account,
        string calldata reason
    ) external onlyRole(KYC_ADMIN_ROLE) {
        if (account == address(0)) revert InvalidAddress();

        blockList[account] = true;
        emit AddedToBlockList(account, reason);
    }

    /**
     * @notice Remove address from block list
     * @param account Address to remove
     */
    function removeFromBlockList(
        address account
    ) external onlyRole(KYC_ADMIN_ROLE) {
        if (sanctionsRecords[account].isSanctioned) revert AccountSanctioned();

        blockList[account] = false;
        emit RemovedFromBlockList(account);
    }

    // ============ KYC Provider Management ============

    /**
     * @notice Register a KYC provider
     * @param provider Address of the provider
     * @param name Provider name
     * @param jurisdiction Provider jurisdiction
     */
    function registerKycProvider(
        address provider,
        string calldata name,
        string calldata jurisdiction
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (provider == address(0)) revert InvalidAddress();
        if (bytes(name).length == 0) revert EmptyName();
        if (kycProviders[provider].registeredAt != 0) revert ProviderAlreadyExists();

        kycProviders[provider] = KycProvider({
            name: name,
            jurisdiction: jurisdiction,
            isActive: true,
            registeredAt: block.timestamp,
            verificationsCount: 0
        });

        _grantRole(KYC_PROVIDER_ROLE, provider);

        emit KycProviderRegistered(provider, name, jurisdiction);
    }

    /**
     * @notice Deactivate a KYC provider
     * @param provider Address of the provider
     */
    function deactivateKycProvider(
        address provider
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (kycProviders[provider].registeredAt == 0) revert ProviderNotFound();

        kycProviders[provider].isActive = false;
        _revokeRole(KYC_PROVIDER_ROLE, provider);

        emit KycProviderDeactivated(provider);
    }

    // ============ Configuration ============

    /**
     * @notice Configure jurisdiction settings
     * @param jurisdiction Jurisdiction code
     * @param kycValidity KYC validity period for this jurisdiction
     * @param defaultRisk Default risk level for this jurisdiction
     */
    function configureJurisdiction(
        string calldata jurisdiction,
        uint256 kycValidity,
        RiskLevel defaultRisk
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bytes(jurisdiction).length == 0) revert InvalidJurisdiction();
        if (kycValidity > 0 && (kycValidity < MIN_KYC_VALIDITY || kycValidity > MAX_KYC_VALIDITY)) {
            revert InvalidValidity();
        }

        jurisdictionKycValidity[jurisdiction] = kycValidity;
        jurisdictionDefaultRisk[jurisdiction] = defaultRisk;

        emit JurisdictionConfigured(jurisdiction, kycValidity, defaultRisk);
    }

    /**
     * @notice Set default KYC validity period
     * @param validity New default validity in seconds
     */
    function setDefaultKycValidity(
        uint256 validity
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (validity < MIN_KYC_VALIDITY || validity > MAX_KYC_VALIDITY) {
            revert InvalidValidity();
        }

        defaultKycValidity = validity;
    }

    // ============ View Functions ============

    /**
     * @notice Get KYC record for an account
     * @param account Address to query
     * @return KycRecord struct
     */
    function getKycRecord(address account) external view returns (KycRecord memory) {
        return kycRecords[account];
    }

    /**
     * @notice Get sanctions record for an account
     * @param account Address to query
     * @return SanctionsRecord struct
     */
    function getSanctionsRecord(address account) external view returns (SanctionsRecord memory) {
        return sanctionsRecords[account];
    }

    /**
     * @notice Check if an account is KYC verified and not expired
     * @param account Address to check
     * @return verified True if verified and not expired
     */
    function isKycVerified(address account) external view returns (bool verified) {
        KycRecord storage record = kycRecords[account];
        return record.status == KYCStatus.VERIFIED && block.timestamp < record.expiresAt;
    }

    /**
     * @notice Check if an account can transact
     * @param account Address to check
     * @return allowed True if allowed
     * @return reason Reason if not allowed
     */
    function canTransact(address account) external view returns (bool allowed, string memory reason) {
        if (sanctionsRecords[account].isSanctioned) {
            return (false, "Account is sanctioned");
        }

        if (blockList[account]) {
            return (false, "Account is blocked");
        }

        // Allow list bypasses KYC check
        if (allowList[account]) {
            return (true, "");
        }

        KycRecord storage record = kycRecords[account];

        if (record.status != KYCStatus.VERIFIED) {
            return (false, "KYC not verified");
        }

        if (block.timestamp >= record.expiresAt) {
            return (false, "KYC expired");
        }

        if (record.riskLevel == RiskLevel.PROHIBITED) {
            return (false, "Risk level prohibited");
        }

        return (true, "");
    }

    /**
     * @notice Get effective risk level for an account
     * @param account Address to check
     * @return RiskLevel
     */
    function getEffectiveRiskLevel(address account) external view returns (RiskLevel) {
        if (sanctionsRecords[account].isSanctioned || blockList[account]) {
            return RiskLevel.PROHIBITED;
        }

        return kycRecords[account].riskLevel;
    }

    /**
     * @notice Check if KYC is expiring soon
     * @param account Address to check
     * @param withinDays Days threshold
     * @return expiringSoon True if expiring within days
     * @return daysRemaining Days until expiration (0 if expired or not verified)
     */
    function isKycExpiringSoon(
        address account,
        uint256 withinDays
    ) external view returns (bool expiringSoon, uint256 daysRemaining) {
        KycRecord storage record = kycRecords[account];

        if (record.status != KYCStatus.VERIFIED || block.timestamp >= record.expiresAt) {
            return (true, 0);
        }

        uint256 timeRemaining = record.expiresAt - block.timestamp;
        daysRemaining = timeRemaining / 1 days;
        expiringSoon = daysRemaining <= withinDays;
    }

    /**
     * @notice Get KYC provider details
     * @param provider Address of the provider
     * @return KycProvider struct
     */
    function getKycProvider(address provider) external view returns (KycProvider memory) {
        return kycProviders[provider];
    }

    // ============ Admin Functions ============

    /**
     * @notice Pause the contract
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
