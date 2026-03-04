// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// forge-lint: disable-next-line(unused-import)
import { Script, console } from "forge-std/Script.sol";
import { DeploymentHelper, DeploymentAddresses } from "../utils/DeploymentAddresses.sol";
import { ERC5564Announcer } from "../../src/privacy/ERC5564Announcer.sol";
import { ERC6538Registry } from "../../src/privacy/ERC6538Registry.sol";
import { PrivateBank } from "../../src/privacy/PrivateBank.sol";
import { RoleManager } from "../../src/privacy/enterprise/RoleManager.sol";
import { StealthLedger } from "../../src/privacy/enterprise/StealthLedger.sol";
import { StealthVault } from "../../src/privacy/enterprise/StealthVault.sol";
import { WithdrawalManager } from "../../src/privacy/enterprise/WithdrawalManager.sol";

/**
 * @title DeployPrivacyScript
 * @notice Deployment script for Privacy contracts (ERC-5564/6538 Stealth Addresses)
 * @dev Deploys ERC5564Announcer, ERC6538Registry, and PrivateBank
 *
 * Deployed Contracts:
 *   - ERC5564Announcer: Stealth address announcement system
 *   - ERC6538Registry: Stealth meta-address registry
 *   - PrivateBank: Privacy-preserving deposit/withdrawal system
 *   - RoleManager: Enterprise role-based access control
 *   - StealthLedger: Enterprise stealth balance tracking
 *   - StealthVault: Enterprise stealth asset custody
 *   - WithdrawalManager: Enterprise withdrawal approval workflow
 *
 * Deployment Order:
 *   1. ERC5564Announcer (Layer 0 - no dependencies)
 *   2. ERC6538Registry (Layer 0 - no dependencies)
 *   3. PrivateBank (Layer 1 - depends on Announcer and Registry)
 *   4. RoleManager (Layer 0 - admin address)
 *   5. StealthLedger (Layer 0 - admin address)
 *   6. StealthVault (Layer 0 - admin address)
 *   7. WithdrawalManager (Layer 0 - admin address + config)
 *
 * Usage:
 *   FOUNDRY_PROFILE=privacy forge script script/deploy-contract/DeployPrivacy.s.sol:DeployPrivacyScript \
 *     --rpc-url <RPC_URL> --broadcast
 */
contract DeployPrivacyScript is DeploymentHelper {
    ERC5564Announcer public announcer;
    ERC6538Registry public registry;
    PrivateBank public privateBank;
    RoleManager public roleManager;
    StealthLedger public stealthLedger;
    StealthVault public stealthVault;
    WithdrawalManager public withdrawalManager;

    // Enterprise privacy defaults — relaxed for testing
    uint256 constant DEFAULT_COOLDOWN_PERIOD = 1 hours;
    uint256 constant DEFAULT_APPROVAL_THRESHOLD = 1;

    function setUp() public { }

    function run() public {
        _initDeployment();

        vm.startBroadcast();

        // ============ Layer 0: No Dependencies ============

        // Deploy ERC5564Announcer
        address existing = _getAddress(DeploymentAddresses.KEY_ANNOUNCER);
        if (existing == address(0)) {
            announcer = new ERC5564Announcer();
            _setAddress(DeploymentAddresses.KEY_ANNOUNCER, address(announcer));
            console.log("ERC5564Announcer deployed at:", address(announcer));
        } else {
            announcer = ERC5564Announcer(existing);
            console.log("ERC5564Announcer: Using existing at", existing);
        }

        // Deploy ERC6538Registry
        existing = _getAddress(DeploymentAddresses.KEY_REGISTRY);
        if (existing == address(0)) {
            registry = new ERC6538Registry();
            _setAddress(DeploymentAddresses.KEY_REGISTRY, address(registry));
            console.log("ERC6538Registry deployed at:", address(registry));
        } else {
            registry = ERC6538Registry(existing);
            console.log("ERC6538Registry: Using existing at", existing);
        }

        // ============ Layer 1: Depends on Layer 0 ============

        // Deploy PrivateBank
        existing = _getAddress(DeploymentAddresses.KEY_PRIVATE_BANK);
        if (existing == address(0)) {
            privateBank = new PrivateBank(address(announcer), address(registry));
            _setAddress(DeploymentAddresses.KEY_PRIVATE_BANK, address(privateBank));
            console.log("PrivateBank deployed at:", address(privateBank));
        } else {
            privateBank = PrivateBank(payable(existing));
            console.log("PrivateBank: Using existing at", existing);
        }

        // ============ Enterprise Privacy Contracts ============

        // Deploy RoleManager
        existing = _getAddress(DeploymentAddresses.KEY_ROLE_MANAGER);
        if (existing == address(0)) {
            roleManager = new RoleManager(msg.sender);
            _setAddress(DeploymentAddresses.KEY_ROLE_MANAGER, address(roleManager));
            console.log("RoleManager deployed at:", address(roleManager));
        } else {
            roleManager = RoleManager(existing);
            console.log("RoleManager: Using existing at", existing);
        }

        // Deploy StealthLedger
        existing = _getAddress(DeploymentAddresses.KEY_STEALTH_LEDGER);
        if (existing == address(0)) {
            stealthLedger = new StealthLedger(msg.sender);
            _setAddress(DeploymentAddresses.KEY_STEALTH_LEDGER, address(stealthLedger));
            console.log("StealthLedger deployed at:", address(stealthLedger));
        } else {
            stealthLedger = StealthLedger(existing);
            console.log("StealthLedger: Using existing at", existing);
        }

        // Deploy StealthVault
        existing = _getAddress(DeploymentAddresses.KEY_STEALTH_VAULT);
        if (existing == address(0)) {
            stealthVault = new StealthVault(msg.sender);
            _setAddress(DeploymentAddresses.KEY_STEALTH_VAULT, address(stealthVault));
            console.log("StealthVault deployed at:", address(stealthVault));
        } else {
            stealthVault = StealthVault(payable(existing));
            console.log("StealthVault: Using existing at", existing);
        }

        // Deploy WithdrawalManager
        existing = _getAddress(DeploymentAddresses.KEY_WITHDRAWAL_MANAGER);
        if (existing == address(0)) {
            uint256 cooldownPeriod = vm.envOr("WITHDRAWAL_COOLDOWN", DEFAULT_COOLDOWN_PERIOD);
            uint256 approvalThreshold = vm.envOr("WITHDRAWAL_APPROVAL_THRESHOLD", DEFAULT_APPROVAL_THRESHOLD);

            withdrawalManager = new WithdrawalManager(msg.sender, cooldownPeriod, approvalThreshold);
            _setAddress(DeploymentAddresses.KEY_WITHDRAWAL_MANAGER, address(withdrawalManager));
            console.log("WithdrawalManager deployed at:", address(withdrawalManager));
            console.log("  Cooldown Period:", cooldownPeriod / 1 hours, "hours");
            console.log("  Approval Threshold:", approvalThreshold);
        } else {
            withdrawalManager = WithdrawalManager(payable(existing));
            console.log("WithdrawalManager: Using existing at", existing);
        }

        vm.stopBroadcast();

        _saveAddresses();

        // Log summary
        console.log("\n=== Privacy Deployment Summary ===");
        console.log("ERC5564Announcer:", address(announcer));
        console.log("  Supported Schemes: secp256k1 (1), secp256r1 (2)");
        console.log("ERC6538Registry:", address(registry));
        console.log("  DOMAIN_SEPARATOR:", vm.toString(registry.DOMAIN_SEPARATOR()));
        console.log("PrivateBank:", address(privateBank));
        console.log("\nEnterprise Privacy:");
        console.log("RoleManager:", address(roleManager));
        console.log("StealthLedger:", address(stealthLedger));
        console.log("StealthVault:", address(stealthVault));
        console.log("WithdrawalManager:", address(withdrawalManager));
        console.log("\nPrivacy system is ready for use:");
        console.log("  1. Users register stealth meta-address in ERC6538Registry");
        console.log("  2. Senders deposit to PrivateBank with computed stealth address");
        console.log("  3. Recipients scan ERC5564 announcements and withdraw");
        console.log("  4. Enterprise: RoleManager controls access, StealthVault holds assets");
    }
}
