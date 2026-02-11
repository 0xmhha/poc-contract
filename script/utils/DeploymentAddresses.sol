// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console } from "forge-std/Script.sol";

/**
 * @title DeploymentAddresses
 * @notice Helper library for managing deployment addresses across scripts
 * @dev Provides functions to save/load deployed contract addresses to/from JSON files
 *
 * Deployment Dependency Graph:
 *
 * Layer 0 (No Dependencies):
 *   - EntryPoint
 *   - Validators (ECDSA, WeightedECDSA, MultiChain)
 *   - Executors (SessionKey, RecurringPayment)
 *   - Hooks (Audit, SpendingLimit)
 *   - Fallbacks (TokenReceiver, FlashLoan)
 *   - wKRC
 *   - PriceOracle
 *   - ERC5564Announcer, ERC6538Registry
 *   - BridgeRateLimiter, FraudProofVerifier
 *   - ERC7715PermissionManager
 *   - KYCRegistry, AuditLogger, ProofOfReserve, RegulatoryRegistry
 *
 * Layer 1 (Depends on Layer 0):
 *   - Kernel -> EntryPoint
 *   - VerifyingPaymaster -> EntryPoint
 *   - ERC20Paymaster -> EntryPoint, PriceOracle
 *   - PrivateBank -> ERC5564Announcer, ERC6538Registry
 *   - BridgeValidator, BridgeGuardian, OptimisticVerifier (signers/guardians config)
 *
 * Layer 2 (Depends on Layer 1):
 *   - KernelFactory -> Kernel
 *   - Permit2Paymaster -> EntryPoint, PriceOracle, Permit2
 *   - SubscriptionManager -> ERC7715PermissionManager
 *   - DEXIntegration -> wKRC, external DEX addresses
 *   - SecureBridge -> BridgeValidator, OptimisticVerifier, BridgeRateLimiter, BridgeGuardian
 */
library DeploymentAddresses {
    // File path constants
    string constant DEPLOYMENTS_DIR = "deployments/";
    string constant ADDRESSES_FILE = "addresses.json";

    // Contract name constants for JSON keys
    string constant KEY_ENTRYPOINT = "entryPoint";
    string constant KEY_KERNEL = "kernel";
    string constant KEY_KERNEL_FACTORY = "kernelFactory";
    string constant KEY_FACTORY_STAKER = "factoryStaker";

    // Validators
    string constant KEY_ECDSA_VALIDATOR = "ecdsaValidator";
    string constant KEY_WEIGHTED_VALIDATOR = "weightedEcdsaValidator";
    string constant KEY_MULTICHAIN_VALIDATOR = "multiChainValidator";
    string constant KEY_MULTISIG_VALIDATOR = "multiSigValidator";
    string constant KEY_WEBAUTHN_VALIDATOR = "webAuthnValidator";

    // Paymasters
    string constant KEY_VERIFYING_PAYMASTER = "verifyingPaymaster";
    string constant KEY_SPONSOR_PAYMASTER = "sponsorPaymaster";
    string constant KEY_ERC20_PAYMASTER = "erc20Paymaster";
    string constant KEY_PERMIT2_PAYMASTER = "permit2Paymaster";

    // Executors
    string constant KEY_SESSION_KEY_EXECUTOR = "sessionKeyExecutor";
    string constant KEY_RECURRING_PAYMENT_EXECUTOR = "recurringPaymentExecutor";

    // Hooks
    string constant KEY_AUDIT_HOOK = "auditHook";
    string constant KEY_SPENDING_LIMIT_HOOK = "spendingLimitHook";

    // Fallbacks
    string constant KEY_TOKEN_RECEIVER_FALLBACK = "tokenReceiverFallback";
    string constant KEY_FLASH_LOAN_FALLBACK = "flashLoanFallback";

    // Plugins
    string constant KEY_AUTO_SWAP_PLUGIN = "autoSwapPlugin";
    string constant KEY_MICRO_LOAN_PLUGIN = "microLoanPlugin";
    string constant KEY_ONRAMP_PLUGIN = "onRampPlugin";

    // Tokens & DeFi
    string constant KEY_PERMIT2 = "permit2";
    string constant KEY_WKRC = "wkrc";
    string constant KEY_USDC = "usdc";
    string constant KEY_PRICE_ORACLE = "priceOracle";
    string constant KEY_LENDING_POOL = "lendingPool";
    string constant KEY_STAKING_VAULT = "stakingVault";

    // UniswapV3
    string constant KEY_UNISWAP_FACTORY = "uniswapV3Factory";
    string constant KEY_UNISWAP_SWAP_ROUTER = "uniswapV3SwapRouter";
    string constant KEY_UNISWAP_QUOTER = "uniswapV3Quoter";
    string constant KEY_UNISWAP_NFT_POSITION_MANAGER = "uniswapV3NftPositionManager";
    string constant KEY_UNISWAP_NFT_DESCRIPTOR = "uniswapV3NftDescriptor";
    string constant KEY_UNISWAP_WKRC_USDC_POOL = "uniswapV3WkrcUsdcPool";

    // Privacy
    string constant KEY_ANNOUNCER = "erc5564Announcer";
    string constant KEY_REGISTRY = "erc6538Registry";
    string constant KEY_PRIVATE_BANK = "privateBank";

    // Bridge
    string constant KEY_BRIDGE_VALIDATOR = "bridgeValidator";
    string constant KEY_BRIDGE_GUARDIAN = "bridgeGuardian";
    string constant KEY_BRIDGE_RATE_LIMITER = "bridgeRateLimiter";
    string constant KEY_OPTIMISTIC_VERIFIER = "optimisticVerifier";
    string constant KEY_FRAUD_PROOF_VERIFIER = "fraudProofVerifier";
    string constant KEY_SECURE_BRIDGE = "secureBridge";

    // Compliance
    string constant KEY_KYC_REGISTRY = "kycRegistry";
    string constant KEY_AUDIT_LOGGER = "auditLogger";
    string constant KEY_PROOF_OF_RESERVE = "proofOfReserve";
    string constant KEY_REGULATORY_REGISTRY = "regulatoryRegistry";

    // Subscription
    string constant KEY_PERMISSION_MANAGER = "erc7715PermissionManager";
    string constant KEY_SUBSCRIPTION_MANAGER = "subscriptionManager";
}

/**
 * @title DeploymentHelper
 * @notice Base contract for deployment scripts with address persistence
 * @dev Inherit from this contract to get automatic address saving/loading
 */
abstract contract DeploymentHelper is Script {
    // Chain ID for deployment file naming
    uint256 public chainId;

    // Force redeploy flag - when true, scripts should deploy fresh regardless of existing addresses
    bool public forceRedeploy;

    // Cached addresses
    mapping(string => address) internal _addresses;

    /**
     * @notice Initialize the deployment helper
     * @dev Call this at the start of run() function.
     *      Always loads existing addresses to preserve the full address map across scripts.
     *      The forceRedeploy flag controls whether individual scripts skip existing contracts,
     *      NOT whether addresses are loaded.
     */
    function _initDeployment() internal {
        chainId = block.chainid;

        // Always load existing addresses first to preserve them in _saveAddresses()
        _loadAddresses();

        // Store force redeploy flag for individual scripts to check
        forceRedeploy = vm.envOr("FORCE_REDEPLOY", false);
        if (forceRedeploy) {
            console.log(
                "FORCE_REDEPLOY=true: Will deploy fresh contracts (existing addresses preserved for other contracts)"
            );
        }
    }

    /**
     * @notice Get the deployment file path for current chain
     */
    function _getDeploymentPath() internal view returns (string memory) {
        return string.concat(
            DeploymentAddresses.DEPLOYMENTS_DIR, vm.toString(chainId), "/", DeploymentAddresses.ADDRESSES_FILE
        );
    }

    /**
     * @notice Load existing addresses from JSON file
     */
    function _loadAddresses() internal {
        string memory path = _getDeploymentPath();

        // Check if file exists
        // forge-lint: disable-next-line(unsafe-cheatcode)
        try vm.readFile(path) returns (string memory json) {
            if (bytes(json).length > 0) {
                // Parse core addresses
                _tryParseAddress(json, DeploymentAddresses.KEY_ENTRYPOINT);
                _tryParseAddress(json, DeploymentAddresses.KEY_KERNEL);
                _tryParseAddress(json, DeploymentAddresses.KEY_KERNEL_FACTORY);
                _tryParseAddress(json, DeploymentAddresses.KEY_FACTORY_STAKER);

                // Validators
                _tryParseAddress(json, DeploymentAddresses.KEY_ECDSA_VALIDATOR);
                _tryParseAddress(json, DeploymentAddresses.KEY_WEIGHTED_VALIDATOR);
                _tryParseAddress(json, DeploymentAddresses.KEY_MULTICHAIN_VALIDATOR);
                _tryParseAddress(json, DeploymentAddresses.KEY_MULTISIG_VALIDATOR);
                _tryParseAddress(json, DeploymentAddresses.KEY_WEBAUTHN_VALIDATOR);

                // Paymasters
                _tryParseAddress(json, DeploymentAddresses.KEY_VERIFYING_PAYMASTER);
                _tryParseAddress(json, DeploymentAddresses.KEY_SPONSOR_PAYMASTER);
                _tryParseAddress(json, DeploymentAddresses.KEY_ERC20_PAYMASTER);
                _tryParseAddress(json, DeploymentAddresses.KEY_PERMIT2_PAYMASTER);

                // Executors
                _tryParseAddress(json, DeploymentAddresses.KEY_SESSION_KEY_EXECUTOR);
                _tryParseAddress(json, DeploymentAddresses.KEY_RECURRING_PAYMENT_EXECUTOR);

                // Hooks
                _tryParseAddress(json, DeploymentAddresses.KEY_AUDIT_HOOK);
                _tryParseAddress(json, DeploymentAddresses.KEY_SPENDING_LIMIT_HOOK);

                // Fallbacks
                _tryParseAddress(json, DeploymentAddresses.KEY_TOKEN_RECEIVER_FALLBACK);
                _tryParseAddress(json, DeploymentAddresses.KEY_FLASH_LOAN_FALLBACK);

                // Plugins
                _tryParseAddress(json, DeploymentAddresses.KEY_AUTO_SWAP_PLUGIN);
                _tryParseAddress(json, DeploymentAddresses.KEY_MICRO_LOAN_PLUGIN);
                _tryParseAddress(json, DeploymentAddresses.KEY_ONRAMP_PLUGIN);

                // Tokens & DeFi
                _tryParseAddress(json, DeploymentAddresses.KEY_PERMIT2);
                _tryParseAddress(json, DeploymentAddresses.KEY_WKRC);
                _tryParseAddress(json, DeploymentAddresses.KEY_USDC);
                _tryParseAddress(json, DeploymentAddresses.KEY_PRICE_ORACLE);
                _tryParseAddress(json, DeploymentAddresses.KEY_LENDING_POOL);
                _tryParseAddress(json, DeploymentAddresses.KEY_STAKING_VAULT);

                // UniswapV3
                _tryParseAddress(json, DeploymentAddresses.KEY_UNISWAP_FACTORY);
                _tryParseAddress(json, DeploymentAddresses.KEY_UNISWAP_SWAP_ROUTER);
                _tryParseAddress(json, DeploymentAddresses.KEY_UNISWAP_QUOTER);
                _tryParseAddress(json, DeploymentAddresses.KEY_UNISWAP_NFT_POSITION_MANAGER);
                _tryParseAddress(json, DeploymentAddresses.KEY_UNISWAP_NFT_DESCRIPTOR);
                _tryParseAddress(json, DeploymentAddresses.KEY_UNISWAP_WKRC_USDC_POOL);

                // Privacy
                _tryParseAddress(json, DeploymentAddresses.KEY_ANNOUNCER);
                _tryParseAddress(json, DeploymentAddresses.KEY_REGISTRY);
                _tryParseAddress(json, DeploymentAddresses.KEY_PRIVATE_BANK);

                // Bridge
                _tryParseAddress(json, DeploymentAddresses.KEY_BRIDGE_VALIDATOR);
                _tryParseAddress(json, DeploymentAddresses.KEY_BRIDGE_GUARDIAN);
                _tryParseAddress(json, DeploymentAddresses.KEY_BRIDGE_RATE_LIMITER);
                _tryParseAddress(json, DeploymentAddresses.KEY_OPTIMISTIC_VERIFIER);
                _tryParseAddress(json, DeploymentAddresses.KEY_FRAUD_PROOF_VERIFIER);
                _tryParseAddress(json, DeploymentAddresses.KEY_SECURE_BRIDGE);

                // Compliance
                _tryParseAddress(json, DeploymentAddresses.KEY_KYC_REGISTRY);
                _tryParseAddress(json, DeploymentAddresses.KEY_AUDIT_LOGGER);
                _tryParseAddress(json, DeploymentAddresses.KEY_PROOF_OF_RESERVE);
                _tryParseAddress(json, DeploymentAddresses.KEY_REGULATORY_REGISTRY);

                // Subscription
                _tryParseAddress(json, DeploymentAddresses.KEY_PERMISSION_MANAGER);
                _tryParseAddress(json, DeploymentAddresses.KEY_SUBSCRIPTION_MANAGER);

                console.log("Loaded existing deployment addresses from:", path);
            }
        } catch {
            console.log("No existing deployment file found, starting fresh");
        }
    }

    /**
     * @notice Try to parse an address from JSON
     */
    function _tryParseAddress(string memory json, string memory key) internal {
        try vm.parseJsonAddress(json, string.concat(".", key)) returns (address addr) {
            if (addr != address(0)) {
                _addresses[key] = addr;
            }
        } catch {
            // Key doesn't exist, skip
        }
    }

    /**
     * @notice Save all addresses to JSON file
     */
    function _saveAddresses() internal {
        string memory obj = "deployment";

        // Build JSON object with all addresses
        if (_addresses[DeploymentAddresses.KEY_ENTRYPOINT] != address(0)) {
            vm.serializeAddress(obj, DeploymentAddresses.KEY_ENTRYPOINT, _addresses[DeploymentAddresses.KEY_ENTRYPOINT]);
        }
        if (_addresses[DeploymentAddresses.KEY_KERNEL] != address(0)) {
            vm.serializeAddress(obj, DeploymentAddresses.KEY_KERNEL, _addresses[DeploymentAddresses.KEY_KERNEL]);
        }
        if (_addresses[DeploymentAddresses.KEY_KERNEL_FACTORY] != address(0)) {
            vm.serializeAddress(
                obj, DeploymentAddresses.KEY_KERNEL_FACTORY, _addresses[DeploymentAddresses.KEY_KERNEL_FACTORY]
            );
        }
        if (_addresses[DeploymentAddresses.KEY_FACTORY_STAKER] != address(0)) {
            vm.serializeAddress(
                obj, DeploymentAddresses.KEY_FACTORY_STAKER, _addresses[DeploymentAddresses.KEY_FACTORY_STAKER]
            );
        }

        // Validators
        if (_addresses[DeploymentAddresses.KEY_ECDSA_VALIDATOR] != address(0)) {
            vm.serializeAddress(
                obj, DeploymentAddresses.KEY_ECDSA_VALIDATOR, _addresses[DeploymentAddresses.KEY_ECDSA_VALIDATOR]
            );
        }
        if (_addresses[DeploymentAddresses.KEY_WEIGHTED_VALIDATOR] != address(0)) {
            vm.serializeAddress(
                obj, DeploymentAddresses.KEY_WEIGHTED_VALIDATOR, _addresses[DeploymentAddresses.KEY_WEIGHTED_VALIDATOR]
            );
        }
        if (_addresses[DeploymentAddresses.KEY_MULTICHAIN_VALIDATOR] != address(0)) {
            vm.serializeAddress(
                obj,
                DeploymentAddresses.KEY_MULTICHAIN_VALIDATOR,
                _addresses[DeploymentAddresses.KEY_MULTICHAIN_VALIDATOR]
            );
        }
        if (_addresses[DeploymentAddresses.KEY_MULTISIG_VALIDATOR] != address(0)) {
            vm.serializeAddress(
                obj, DeploymentAddresses.KEY_MULTISIG_VALIDATOR, _addresses[DeploymentAddresses.KEY_MULTISIG_VALIDATOR]
            );
        }
        if (_addresses[DeploymentAddresses.KEY_WEBAUTHN_VALIDATOR] != address(0)) {
            vm.serializeAddress(
                obj, DeploymentAddresses.KEY_WEBAUTHN_VALIDATOR, _addresses[DeploymentAddresses.KEY_WEBAUTHN_VALIDATOR]
            );
        }

        // Paymasters
        if (_addresses[DeploymentAddresses.KEY_VERIFYING_PAYMASTER] != address(0)) {
            vm.serializeAddress(
                obj,
                DeploymentAddresses.KEY_VERIFYING_PAYMASTER,
                _addresses[DeploymentAddresses.KEY_VERIFYING_PAYMASTER]
            );
        }
        if (_addresses[DeploymentAddresses.KEY_SPONSOR_PAYMASTER] != address(0)) {
            vm.serializeAddress(
                obj, DeploymentAddresses.KEY_SPONSOR_PAYMASTER, _addresses[DeploymentAddresses.KEY_SPONSOR_PAYMASTER]
            );
        }
        if (_addresses[DeploymentAddresses.KEY_ERC20_PAYMASTER] != address(0)) {
            vm.serializeAddress(
                obj, DeploymentAddresses.KEY_ERC20_PAYMASTER, _addresses[DeploymentAddresses.KEY_ERC20_PAYMASTER]
            );
        }
        if (_addresses[DeploymentAddresses.KEY_PERMIT2_PAYMASTER] != address(0)) {
            vm.serializeAddress(
                obj, DeploymentAddresses.KEY_PERMIT2_PAYMASTER, _addresses[DeploymentAddresses.KEY_PERMIT2_PAYMASTER]
            );
        }

        // Executors
        if (_addresses[DeploymentAddresses.KEY_SESSION_KEY_EXECUTOR] != address(0)) {
            vm.serializeAddress(
                obj,
                DeploymentAddresses.KEY_SESSION_KEY_EXECUTOR,
                _addresses[DeploymentAddresses.KEY_SESSION_KEY_EXECUTOR]
            );
        }
        if (_addresses[DeploymentAddresses.KEY_RECURRING_PAYMENT_EXECUTOR] != address(0)) {
            vm.serializeAddress(
                obj,
                DeploymentAddresses.KEY_RECURRING_PAYMENT_EXECUTOR,
                _addresses[DeploymentAddresses.KEY_RECURRING_PAYMENT_EXECUTOR]
            );
        }

        // Hooks
        if (_addresses[DeploymentAddresses.KEY_AUDIT_HOOK] != address(0)) {
            vm.serializeAddress(obj, DeploymentAddresses.KEY_AUDIT_HOOK, _addresses[DeploymentAddresses.KEY_AUDIT_HOOK]);
        }
        if (_addresses[DeploymentAddresses.KEY_SPENDING_LIMIT_HOOK] != address(0)) {
            vm.serializeAddress(
                obj,
                DeploymentAddresses.KEY_SPENDING_LIMIT_HOOK,
                _addresses[DeploymentAddresses.KEY_SPENDING_LIMIT_HOOK]
            );
        }

        // Fallbacks
        if (_addresses[DeploymentAddresses.KEY_TOKEN_RECEIVER_FALLBACK] != address(0)) {
            vm.serializeAddress(
                obj,
                DeploymentAddresses.KEY_TOKEN_RECEIVER_FALLBACK,
                _addresses[DeploymentAddresses.KEY_TOKEN_RECEIVER_FALLBACK]
            );
        }
        if (_addresses[DeploymentAddresses.KEY_FLASH_LOAN_FALLBACK] != address(0)) {
            vm.serializeAddress(
                obj,
                DeploymentAddresses.KEY_FLASH_LOAN_FALLBACK,
                _addresses[DeploymentAddresses.KEY_FLASH_LOAN_FALLBACK]
            );
        }

        // Plugins
        if (_addresses[DeploymentAddresses.KEY_AUTO_SWAP_PLUGIN] != address(0)) {
            vm.serializeAddress(
                obj, DeploymentAddresses.KEY_AUTO_SWAP_PLUGIN, _addresses[DeploymentAddresses.KEY_AUTO_SWAP_PLUGIN]
            );
        }
        if (_addresses[DeploymentAddresses.KEY_MICRO_LOAN_PLUGIN] != address(0)) {
            vm.serializeAddress(
                obj, DeploymentAddresses.KEY_MICRO_LOAN_PLUGIN, _addresses[DeploymentAddresses.KEY_MICRO_LOAN_PLUGIN]
            );
        }
        if (_addresses[DeploymentAddresses.KEY_ONRAMP_PLUGIN] != address(0)) {
            vm.serializeAddress(
                obj, DeploymentAddresses.KEY_ONRAMP_PLUGIN, _addresses[DeploymentAddresses.KEY_ONRAMP_PLUGIN]
            );
        }

        // Tokens & DeFi
        if (_addresses[DeploymentAddresses.KEY_PERMIT2] != address(0)) {
            vm.serializeAddress(obj, DeploymentAddresses.KEY_PERMIT2, _addresses[DeploymentAddresses.KEY_PERMIT2]);
        }
        if (_addresses[DeploymentAddresses.KEY_WKRC] != address(0)) {
            vm.serializeAddress(obj, DeploymentAddresses.KEY_WKRC, _addresses[DeploymentAddresses.KEY_WKRC]);
        }
        if (_addresses[DeploymentAddresses.KEY_USDC] != address(0)) {
            vm.serializeAddress(obj, DeploymentAddresses.KEY_USDC, _addresses[DeploymentAddresses.KEY_USDC]);
        }
        if (_addresses[DeploymentAddresses.KEY_PRICE_ORACLE] != address(0)) {
            vm.serializeAddress(
                obj, DeploymentAddresses.KEY_PRICE_ORACLE, _addresses[DeploymentAddresses.KEY_PRICE_ORACLE]
            );
        }
        if (_addresses[DeploymentAddresses.KEY_LENDING_POOL] != address(0)) {
            vm.serializeAddress(
                obj, DeploymentAddresses.KEY_LENDING_POOL, _addresses[DeploymentAddresses.KEY_LENDING_POOL]
            );
        }
        if (_addresses[DeploymentAddresses.KEY_STAKING_VAULT] != address(0)) {
            vm.serializeAddress(
                obj, DeploymentAddresses.KEY_STAKING_VAULT, _addresses[DeploymentAddresses.KEY_STAKING_VAULT]
            );
        }

        // UniswapV3
        if (_addresses[DeploymentAddresses.KEY_UNISWAP_FACTORY] != address(0)) {
            vm.serializeAddress(
                obj, DeploymentAddresses.KEY_UNISWAP_FACTORY, _addresses[DeploymentAddresses.KEY_UNISWAP_FACTORY]
            );
        }
        if (_addresses[DeploymentAddresses.KEY_UNISWAP_SWAP_ROUTER] != address(0)) {
            vm.serializeAddress(
                obj,
                DeploymentAddresses.KEY_UNISWAP_SWAP_ROUTER,
                _addresses[DeploymentAddresses.KEY_UNISWAP_SWAP_ROUTER]
            );
        }
        if (_addresses[DeploymentAddresses.KEY_UNISWAP_QUOTER] != address(0)) {
            vm.serializeAddress(
                obj, DeploymentAddresses.KEY_UNISWAP_QUOTER, _addresses[DeploymentAddresses.KEY_UNISWAP_QUOTER]
            );
        }
        if (_addresses[DeploymentAddresses.KEY_UNISWAP_NFT_POSITION_MANAGER] != address(0)) {
            vm.serializeAddress(
                obj,
                DeploymentAddresses.KEY_UNISWAP_NFT_POSITION_MANAGER,
                _addresses[DeploymentAddresses.KEY_UNISWAP_NFT_POSITION_MANAGER]
            );
        }
        if (_addresses[DeploymentAddresses.KEY_UNISWAP_NFT_DESCRIPTOR] != address(0)) {
            vm.serializeAddress(
                obj,
                DeploymentAddresses.KEY_UNISWAP_NFT_DESCRIPTOR,
                _addresses[DeploymentAddresses.KEY_UNISWAP_NFT_DESCRIPTOR]
            );
        }
        if (_addresses[DeploymentAddresses.KEY_UNISWAP_WKRC_USDC_POOL] != address(0)) {
            vm.serializeAddress(
                obj,
                DeploymentAddresses.KEY_UNISWAP_WKRC_USDC_POOL,
                _addresses[DeploymentAddresses.KEY_UNISWAP_WKRC_USDC_POOL]
            );
        }

        // Privacy
        if (_addresses[DeploymentAddresses.KEY_ANNOUNCER] != address(0)) {
            vm.serializeAddress(obj, DeploymentAddresses.KEY_ANNOUNCER, _addresses[DeploymentAddresses.KEY_ANNOUNCER]);
        }
        if (_addresses[DeploymentAddresses.KEY_REGISTRY] != address(0)) {
            vm.serializeAddress(obj, DeploymentAddresses.KEY_REGISTRY, _addresses[DeploymentAddresses.KEY_REGISTRY]);
        }
        if (_addresses[DeploymentAddresses.KEY_PRIVATE_BANK] != address(0)) {
            vm.serializeAddress(
                obj, DeploymentAddresses.KEY_PRIVATE_BANK, _addresses[DeploymentAddresses.KEY_PRIVATE_BANK]
            );
        }

        // Bridge
        if (_addresses[DeploymentAddresses.KEY_BRIDGE_VALIDATOR] != address(0)) {
            vm.serializeAddress(
                obj, DeploymentAddresses.KEY_BRIDGE_VALIDATOR, _addresses[DeploymentAddresses.KEY_BRIDGE_VALIDATOR]
            );
        }
        if (_addresses[DeploymentAddresses.KEY_BRIDGE_GUARDIAN] != address(0)) {
            vm.serializeAddress(
                obj, DeploymentAddresses.KEY_BRIDGE_GUARDIAN, _addresses[DeploymentAddresses.KEY_BRIDGE_GUARDIAN]
            );
        }
        if (_addresses[DeploymentAddresses.KEY_BRIDGE_RATE_LIMITER] != address(0)) {
            vm.serializeAddress(
                obj,
                DeploymentAddresses.KEY_BRIDGE_RATE_LIMITER,
                _addresses[DeploymentAddresses.KEY_BRIDGE_RATE_LIMITER]
            );
        }
        if (_addresses[DeploymentAddresses.KEY_OPTIMISTIC_VERIFIER] != address(0)) {
            vm.serializeAddress(
                obj,
                DeploymentAddresses.KEY_OPTIMISTIC_VERIFIER,
                _addresses[DeploymentAddresses.KEY_OPTIMISTIC_VERIFIER]
            );
        }
        if (_addresses[DeploymentAddresses.KEY_FRAUD_PROOF_VERIFIER] != address(0)) {
            vm.serializeAddress(
                obj,
                DeploymentAddresses.KEY_FRAUD_PROOF_VERIFIER,
                _addresses[DeploymentAddresses.KEY_FRAUD_PROOF_VERIFIER]
            );
        }
        if (_addresses[DeploymentAddresses.KEY_SECURE_BRIDGE] != address(0)) {
            vm.serializeAddress(
                obj, DeploymentAddresses.KEY_SECURE_BRIDGE, _addresses[DeploymentAddresses.KEY_SECURE_BRIDGE]
            );
        }

        // Compliance
        if (_addresses[DeploymentAddresses.KEY_KYC_REGISTRY] != address(0)) {
            vm.serializeAddress(
                obj, DeploymentAddresses.KEY_KYC_REGISTRY, _addresses[DeploymentAddresses.KEY_KYC_REGISTRY]
            );
        }
        if (_addresses[DeploymentAddresses.KEY_AUDIT_LOGGER] != address(0)) {
            vm.serializeAddress(
                obj, DeploymentAddresses.KEY_AUDIT_LOGGER, _addresses[DeploymentAddresses.KEY_AUDIT_LOGGER]
            );
        }
        if (_addresses[DeploymentAddresses.KEY_PROOF_OF_RESERVE] != address(0)) {
            vm.serializeAddress(
                obj, DeploymentAddresses.KEY_PROOF_OF_RESERVE, _addresses[DeploymentAddresses.KEY_PROOF_OF_RESERVE]
            );
        }
        if (_addresses[DeploymentAddresses.KEY_REGULATORY_REGISTRY] != address(0)) {
            vm.serializeAddress(
                obj,
                DeploymentAddresses.KEY_REGULATORY_REGISTRY,
                _addresses[DeploymentAddresses.KEY_REGULATORY_REGISTRY]
            );
        }

        // Subscription (last to get final JSON output)
        if (_addresses[DeploymentAddresses.KEY_PERMISSION_MANAGER] != address(0)) {
            vm.serializeAddress(
                obj, DeploymentAddresses.KEY_PERMISSION_MANAGER, _addresses[DeploymentAddresses.KEY_PERMISSION_MANAGER]
            );
        }

        string memory finalJson;
        if (_addresses[DeploymentAddresses.KEY_SUBSCRIPTION_MANAGER] != address(0)) {
            finalJson = vm.serializeAddress(
                obj,
                DeploymentAddresses.KEY_SUBSCRIPTION_MANAGER,
                _addresses[DeploymentAddresses.KEY_SUBSCRIPTION_MANAGER]
            );
        } else {
            // Create a dummy entry if subscription manager not set
            finalJson = vm.serializeString(obj, "_chainId", vm.toString(chainId));
        }

        // Ensure directory exists and write file
        string memory path = _getDeploymentPath();

        // Extract directory path from file path (e.g., "deployments/31337/addresses.json" -> "deployments/31337")
        string memory dirPath = string.concat(DeploymentAddresses.DEPLOYMENTS_DIR, vm.toString(chainId));

        // Create directory if it doesn't exist (recursive = true to create parent dirs if needed)
        // forge-lint: disable-next-line(unsafe-cheatcode)
        try vm.createDir(dirPath, true) {
        // Directory created successfully
        }
            catch {
            // Directory creation failed, but continue - vm.writeJson might still work
            // or the directory might already exist
        }

        // Write JSON file
        // forge-lint: disable-next-line(unsafe-cheatcode)
        try vm.writeJson(finalJson, path) {
            console.log("Saved deployment addresses to:", path);
        } catch {
            console.log("Warning: Could not save addresses to file. Add fs_permissions to foundry.toml:");
            console.log("  fs_permissions = [{ access = \"read-write\", path = \"./deployments\" }]");
            console.log("Deployment was successful. Addresses are logged above.");
        }
    }

    /**
     * @notice Get a previously deployed address
     * @param key The address key from DeploymentAddresses
     * @return The address, or address(0) if not found or if forceRedeploy is true
     * @dev Returns address(0) when forceRedeploy is true so deploy scripts
     *      will redeploy contracts. Dependencies should use _getAddressOrEnv
     *      or _requireDependency which access _addresses directly.
     */
    function _getAddress(string memory key) internal view returns (address) {
        if (forceRedeploy) return address(0);
        return _addresses[key];
    }

    /**
     * @notice Set an address after deployment
     * @param key The address key from DeploymentAddresses
     * @param addr The deployed contract address
     */
    function _setAddress(string memory key, address addr) internal {
        _addresses[key] = addr;
    }

    /**
     * @notice Require a dependency address to exist
     * @param key The address key to check
     * @param dependencyName Human readable name for error message
     */
    function _requireDependency(string memory key, string memory dependencyName) internal view {
        require(
            _addresses[key] != address(0),
            string.concat(
                "Missing dependency: ", dependencyName, ". Deploy it first or set ", key, " in the addresses file."
            )
        );
    }

    /**
     * @notice Get address with fallback to environment variable
     * @param key The address key from DeploymentAddresses
     * @param envVar The environment variable name to use as fallback
     * @return The address from cache, env var, or address(0)
     */
    function _getAddressOrEnv(string memory key, string memory envVar) internal returns (address) {
        address cached = _addresses[key];
        if (cached != address(0)) {
            return cached;
        }

        // Try environment variable
        address envAddr = vm.envOr(envVar, address(0));
        if (envAddr != address(0)) {
            _addresses[key] = envAddr;
            return envAddr;
        }

        return address(0);
    }
}
