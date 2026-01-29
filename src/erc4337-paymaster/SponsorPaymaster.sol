// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BasePaymaster } from "./BasePaymaster.sol";
import { IEntryPoint } from "../erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "../erc4337-entrypoint/interfaces/PackedUserOperation.sol";
import { UserOperationLib } from "../erc4337-entrypoint/UserOperationLib.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";

/**
 * @title SponsorPaymaster
 * @notice A paymaster that sponsors gas for approved users/operations
 * @dev Multiple sponsorship modes:
 *      1. Whitelist Mode: Sponsor gas for whitelisted addresses
 *      2. Signature Mode: Sponsor gas for operations signed by sponsor
 *      3. Budget Mode: Sponsor up to a budget per user/period
 *      4. Campaign Mode: Time-limited promotional sponsorship
 *
 * Use Cases:
 * - Onboarding new users with free transactions
 * - Corporate accounts covering employee transactions
 * - DApp promotions and campaigns
 * - Protocol subsidies for important operations
 *
 * PaymasterData format for Signature Mode:
 *   [0:8] - validUntil (uint48)
 *   [8:16] - validAfter (uint48)
 *   [16:20] - sponsorshipType (uint32)
 *   [20:84] - sponsor signature (64 bytes)
 */
contract SponsorPaymaster is BasePaymaster {
    using UserOperationLib for PackedUserOperation;
    using ECDSA for bytes32;

    /// @notice Sponsorship types
    enum SponsorshipType {
        WHITELIST, // 0: Simple whitelist
        SIGNATURE, // 1: Requires sponsor signature
        BUDGET, // 2: Budget-limited sponsorship
        CAMPAIGN // 3: Time-limited campaign
    }

    /// @notice User budget tracking
    struct UserBudget {
        uint256 spent;
        uint256 limit;
        uint256 periodStart;
        uint256 periodDuration;
    }

    /// @notice Campaign configuration
    struct Campaign {
        string name;
        uint256 startTime;
        uint256 endTime;
        uint256 totalBudget;
        uint256 spent;
        uint256 maxPerUser;
        bool isActive;
        bytes4 targetSelector; // Optional: only sponsor specific functions
        address targetContract; // Optional: only sponsor calls to specific contract
    }

    /// @notice Signer for signature mode
    address public signer;

    /// @notice Whitelisted addresses
    mapping(address => bool) public whitelist;

    /// @notice User budgets: user => budget
    mapping(address => UserBudget) public userBudgets;

    /// @notice Campaigns: campaignId => Campaign
    mapping(uint256 => Campaign) public campaigns;

    /// @notice User campaign usage: campaignId => user => spent
    mapping(uint256 => mapping(address => uint256)) public campaignUserSpent;

    /// @notice Next campaign ID
    uint256 public nextCampaignId;

    /// @notice Default budget limit per user
    uint256 public defaultBudgetLimit;

    /// @notice Default budget period (default: 1 day)
    uint256 public defaultBudgetPeriod;

    /// @notice Nonces for replay protection
    mapping(address => uint256) public nonces;

    // Events
    event WhitelistUpdated(address indexed account, bool isWhitelisted);
    event SignerUpdated(address indexed oldSigner, address indexed newSigner);
    event UserBudgetSet(address indexed user, uint256 limit, uint256 periodDuration);
    event CampaignCreated(uint256 indexed campaignId, string name, uint256 budget);
    event CampaignUpdated(uint256 indexed campaignId, bool isActive);
    event GasSponsored(address indexed user, SponsorshipType sponsorshipType, uint256 gasCost, uint256 campaignId);

    // Errors
    error NotWhitelisted();
    error InvalidSignature();
    error BudgetExceeded();
    error CampaignNotActive();
    error CampaignBudgetExceeded();
    error UserCampaignLimitExceeded();
    error TargetNotAllowed();
    error InvalidPaymasterData();

    /**
     * @notice Constructor
     * @param _entryPoint The EntryPoint contract address
     * @param _owner The owner address
     * @param _signer The signer for signature mode
     */
    constructor(IEntryPoint _entryPoint, address _owner, address _signer) BasePaymaster(_entryPoint, _owner) {
        signer = _signer;
        defaultBudgetPeriod = 1 days;
        defaultBudgetLimit = 0.1 ether; // Default: 0.1 ETH per day
    }

    // ============ Configuration ============

    /**
     * @notice Update the signer address
     * @param _signer New signer address
     */
    function setSigner(address _signer) external onlyOwner {
        address oldSigner = signer;
        signer = _signer;
        emit SignerUpdated(oldSigner, _signer);
    }

    /**
     * @notice Set default budget parameters
     * @param _limit Default budget limit
     * @param _period Default budget period
     */
    function setDefaultBudget(uint256 _limit, uint256 _period) external onlyOwner {
        defaultBudgetLimit = _limit;
        defaultBudgetPeriod = _period;
    }

    /**
     * @notice Add/remove address from whitelist
     * @param account The address
     * @param allowed Whether to whitelist
     */
    function setWhitelist(address account, bool allowed) external onlyOwner {
        whitelist[account] = allowed;
        emit WhitelistUpdated(account, allowed);
    }

    /**
     * @notice Batch whitelist update
     * @param accounts Array of addresses
     * @param allowed Whether to whitelist all
     */
    function setWhitelistBatch(address[] calldata accounts, bool allowed) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            whitelist[accounts[i]] = allowed;
            emit WhitelistUpdated(accounts[i], allowed);
        }
    }

    /**
     * @notice Set budget for a specific user
     * @param user The user address
     * @param limit Budget limit
     * @param periodDuration Budget period in seconds
     */
    function setUserBudget(address user, uint256 limit, uint256 periodDuration) external onlyOwner {
        userBudgets[user] =
            UserBudget({ spent: 0, limit: limit, periodStart: block.timestamp, periodDuration: periodDuration });
        emit UserBudgetSet(user, limit, periodDuration);
    }

    // ============ Campaign Management ============

    /**
     * @notice Create a new sponsorship campaign
     * @param name Campaign name
     * @param startTime Campaign start time
     * @param endTime Campaign end time
     * @param totalBudget Total budget for the campaign
     * @param maxPerUser Maximum spend per user
     * @param targetSelector Optional function selector filter
     * @param targetContract Optional contract address filter
     */
    function createCampaign(
        string calldata name,
        uint256 startTime,
        uint256 endTime,
        uint256 totalBudget,
        uint256 maxPerUser,
        bytes4 targetSelector,
        address targetContract
    ) external onlyOwner returns (uint256 campaignId) {
        campaignId = nextCampaignId++;

        campaigns[campaignId] = Campaign({
            name: name,
            startTime: startTime,
            endTime: endTime,
            totalBudget: totalBudget,
            spent: 0,
            maxPerUser: maxPerUser,
            isActive: true,
            targetSelector: targetSelector,
            targetContract: targetContract
        });

        emit CampaignCreated(campaignId, name, totalBudget);
    }

    /**
     * @notice Update campaign status
     * @param campaignId The campaign ID
     * @param isActive New status
     */
    function setCampaignActive(uint256 campaignId, bool isActive) external onlyOwner {
        campaigns[campaignId].isActive = isActive;
        emit CampaignUpdated(campaignId, isActive);
    }

    // ============ Internal Validation ============

    /**
     * @notice Internal validation logic
     * @param userOp The user operation
     * @param maxCost Maximum cost in native currency
     * @return context Encoded context for postOp
     * @return validationData Validation result with time range
     */
    function _validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32, uint256 maxCost)
        internal
        override
        returns (bytes memory context, uint256 validationData)
    {
        bytes calldata paymasterData = _parsePaymasterData(userOp.paymasterAndData);

        // Determine sponsorship type from data
        SponsorshipType sponsorType;
        uint256 campaignId = 0;
        uint48 validUntil = 0;
        uint48 validAfter = 0;

        if (paymasterData.length == 0) {
            // Default: whitelist mode
            sponsorType = SponsorshipType.WHITELIST;
        } else if (paymasterData.length >= 4) {
            sponsorType = SponsorshipType(uint32(bytes4(paymasterData[0:4])));

            if (sponsorType == SponsorshipType.SIGNATURE && paymasterData.length >= 84) {
                // Parse signature mode data
                validUntil = uint48(bytes6(paymasterData[4:10]));
                validAfter = uint48(bytes6(paymasterData[10:16]));

                // Verify signature
                bytes memory sig = paymasterData[16:80];
                // forge-lint: disable-next-line(asm-keccak256)
                bytes32 hash = keccak256(abi.encode(userOp.sender, nonces[userOp.sender]++, validUntil, validAfter));

                if (signer != ECDSA.recover(ECDSA.toEthSignedMessageHash(hash), sig)) {
                    return ("", _packValidationDataFailure(validUntil, validAfter));
                }
            } else if (sponsorType == SponsorshipType.CAMPAIGN && paymasterData.length >= 36) {
                campaignId = uint256(bytes32(paymasterData[4:36]));
            }
        }

        // Validate based on sponsorship type
        if (sponsorType == SponsorshipType.WHITELIST) {
            if (!whitelist[userOp.sender]) {
                return ("", _packValidationDataFailure(0, 0));
            }
        } else if (sponsorType == SponsorshipType.BUDGET) {
            if (!_checkAndUpdateBudget(userOp.sender, maxCost)) {
                return ("", _packValidationDataFailure(0, 0));
            }
        } else if (sponsorType == SponsorshipType.CAMPAIGN) {
            if (!_validateCampaign(campaignId, userOp, maxCost)) {
                return ("", _packValidationDataFailure(0, 0));
            }
        }
        // SIGNATURE type already validated above

        // Encode context for postOp
        context = abi.encode(userOp.sender, sponsorType, maxCost, campaignId);

        return (context, _packValidationDataSuccess(validUntil, validAfter));
    }

    /**
     * @notice Post-operation handler
     * @param mode Operation result mode
     * @param context Encoded context
     * @param actualGasCost Actual gas cost
     * @param actualUserOpFeePerGas Actual fee per gas
     */
    function _postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)
        internal
        override
    {
        (actualUserOpFeePerGas); // silence unused warning

        if (mode == PostOpMode.postOpReverted) {
            return;
        }

        (address user, SponsorshipType sponsorType, uint256 maxCost, uint256 campaignId) =
            abi.decode(context, (address, SponsorshipType, uint256, uint256));

        (maxCost); // silence unused warning

        // Update spending based on type
        if (sponsorType == SponsorshipType.BUDGET) {
            userBudgets[user].spent += actualGasCost;
        } else if (sponsorType == SponsorshipType.CAMPAIGN) {
            campaigns[campaignId].spent += actualGasCost;
            campaignUserSpent[campaignId][user] += actualGasCost;
        }

        emit GasSponsored(user, sponsorType, actualGasCost, campaignId);
    }

    // ============ Internal Helpers ============

    function _checkAndUpdateBudget(address user, uint256 amount) internal returns (bool) {
        UserBudget storage budget = userBudgets[user];

        // Initialize default budget if not set
        if (budget.limit == 0) {
            budget.limit = defaultBudgetLimit;
            budget.periodDuration = defaultBudgetPeriod;
            budget.periodStart = block.timestamp;
        }

        // Reset period if expired
        if (block.timestamp >= budget.periodStart + budget.periodDuration) {
            budget.spent = 0;
            budget.periodStart = block.timestamp;
        }

        // Check budget
        if (budget.spent + amount > budget.limit) {
            return false;
        }

        return true;
    }

    function _validateCampaign(uint256 campaignId, PackedUserOperation calldata userOp, uint256 maxCost)
        internal
        view
        returns (bool)
    {
        Campaign storage campaign = campaigns[campaignId];

        // Check campaign is active
        if (!campaign.isActive) return false;

        // Check time range
        if (block.timestamp < campaign.startTime) return false;
        if (block.timestamp > campaign.endTime) return false;

        // Check total budget
        if (campaign.spent + maxCost > campaign.totalBudget) return false;

        // Check per-user limit
        if (campaign.maxPerUser > 0) {
            if (campaignUserSpent[campaignId][userOp.sender] + maxCost > campaign.maxPerUser) {
                return false;
            }
        }

        // Check target contract filter
        if (campaign.targetContract != address(0)) {
            // Extract target from callData (first 20 bytes after function selector)
            bytes calldata callData = userOp.callData;
            if (callData.length < 24) return false;

            address target = address(bytes20(callData[4:24]));
            if (target != campaign.targetContract) return false;
        }

        // Check target selector filter
        if (campaign.targetSelector != bytes4(0)) {
            bytes calldata callData = userOp.callData;
            if (callData.length < 4) return false;

            bytes4 selector = bytes4(callData[0:4]);
            if (selector != campaign.targetSelector) return false;
        }

        return true;
    }

    // ============ View Functions ============

    /**
     * @notice Check if an address is whitelisted
     * @param account The address to check
     */
    function isWhitelisted(address account) external view returns (bool) {
        return whitelist[account];
    }

    /**
     * @notice Get user's remaining budget
     * @param user The user address
     */
    function getRemainingBudget(address user) external view returns (uint256) {
        UserBudget storage budget = userBudgets[user];

        uint256 limit = budget.limit > 0 ? budget.limit : defaultBudgetLimit;
        uint256 periodDuration = budget.periodDuration > 0 ? budget.periodDuration : defaultBudgetPeriod;

        // Check if period expired (would reset)
        if (block.timestamp >= budget.periodStart + periodDuration) {
            return limit;
        }

        if (budget.spent >= limit) return 0;
        return limit - budget.spent;
    }

    /**
     * @notice Get campaign info
     * @param campaignId The campaign ID
     */
    function getCampaign(uint256 campaignId) external view returns (Campaign memory) {
        return campaigns[campaignId];
    }

    /**
     * @notice Get user's spending in a campaign
     * @param campaignId The campaign ID
     * @param user The user address
     */
    function getCampaignUserSpent(uint256 campaignId, address user) external view returns (uint256) {
        return campaignUserSpent[campaignId][user];
    }

    /**
     * @notice Check if campaign is currently valid
     * @param campaignId The campaign ID
     */
    function isCampaignValid(uint256 campaignId) external view returns (bool) {
        Campaign storage campaign = campaigns[campaignId];
        return campaign.isActive && block.timestamp >= campaign.startTime && block.timestamp <= campaign.endTime
            && campaign.spent < campaign.totalBudget;
    }
}
