// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {DeploymentHelper, DeploymentAddresses} from "../utils/DeploymentAddresses.sol";

// Privacy (ERC-5564/6538)
import {ERC5564Announcer} from "../../src/privacy/ERC5564Announcer.sol";
import {ERC6538Registry} from "../../src/privacy/ERC6538Registry.sol";
import {PrivateBank} from "../../src/privacy/PrivateBank.sol";

/**
 * @title DeployPrivacyScript
 * @notice Privacy (ERC-5564/6538) 스텔스 주소 컨트랙트 배포
 * @dev 배포되는 컨트랙트:
 *   - ERC5564Announcer: 스텔스 주소 공지 (Stealth Address Announcement)
 *   - ERC6538Registry: 스텔스 메타 주소 등록 (Stealth Meta-Address Registry)
 *   - PrivateBank: 프라이빗 입출금 (Private Deposits/Withdrawals)
 *
 * 의존성:
 *   - PrivateBank는 ERC5564Announcer와 ERC6538Registry가 필요
 *
 * 표준 참조:
 *   - ERC-5564: Stealth Addresses
 *   - ERC-6538: Stealth Meta-Address Registry
 *
 * Usage:
 *   forge script script/deploy/DeployPrivacy.s.sol:DeployPrivacyScript \
 *     --rpc-url http://127.0.0.1:8545 --broadcast
 *
 * Environment Variables:
 *   - SKIP_EXISTING: 이미 배포된 컨트랙트 스킵 (기본값: true)
 */
contract DeployPrivacyScript is DeploymentHelper {
    function run() public {
        _initDeployment();

        bool skipExisting = vm.envOr("SKIP_EXISTING", true);

        console.log("=== Privacy (ERC-5564/6538) Deployment ===");
        console.log("Chain ID:", chainId);
        console.log("Skip Existing:", skipExisting);
        console.log("");

        vm.startBroadcast();

        // ============================================
        // ERC-5564: Stealth Address Announcement
        // ============================================
        console.log("--- ERC-5564 Stealth Addresses ---");

        // ERC5564Announcer - 스텔스 주소 공지
        address announcerAddr = _getAddress(DeploymentAddresses.KEY_ANNOUNCER);
        if (!skipExisting || announcerAddr == address(0)) {
            ERC5564Announcer announcer = new ERC5564Announcer();
            _setAddress(DeploymentAddresses.KEY_ANNOUNCER, address(announcer));
            announcerAddr = address(announcer);
            console.log("[NEW] ERC5564Announcer:", announcerAddr);
        } else {
            console.log("[SKIP] ERC5564Announcer:", announcerAddr);
        }

        // ============================================
        // ERC-6538: Stealth Meta-Address Registry
        // ============================================
        console.log("");
        console.log("--- ERC-6538 Stealth Meta-Address Registry ---");

        // ERC6538Registry - 스텔스 메타 주소 등록
        address registryAddr = _getAddress(DeploymentAddresses.KEY_REGISTRY);
        if (!skipExisting || registryAddr == address(0)) {
            ERC6538Registry registry = new ERC6538Registry();
            _setAddress(DeploymentAddresses.KEY_REGISTRY, address(registry));
            registryAddr = address(registry);
            console.log("[NEW] ERC6538Registry:", registryAddr);
        } else {
            console.log("[SKIP] ERC6538Registry:", registryAddr);
        }

        // ============================================
        // PrivateBank: 프라이빗 입출금
        // ============================================
        console.log("");
        console.log("--- Private Bank ---");

        // PrivateBank - 프라이빗 입출금 (Announcer + Registry 필요)
        address privateBankAddr = _getAddress(DeploymentAddresses.KEY_PRIVATE_BANK);
        if (!skipExisting || privateBankAddr == address(0)) {
            if (announcerAddr != address(0) && registryAddr != address(0)) {
                PrivateBank privateBank = new PrivateBank(announcerAddr, registryAddr);
                _setAddress(DeploymentAddresses.KEY_PRIVATE_BANK, address(privateBank));
                console.log("[NEW] PrivateBank:", address(privateBank));
            } else {
                console.log("[SKIP] PrivateBank: Missing dependencies (Announcer or Registry)");
            }
        } else {
            console.log("[SKIP] PrivateBank:", privateBankAddr);
        }

        vm.stopBroadcast();

        _saveAddresses();

        console.log("");
        console.log("=== Privacy Deployment Complete ===");
        console.log("Addresses saved to:", _getDeploymentPath());
        console.log("");
        console.log("Stealth Address Flow:");
        console.log("  1. Recipient registers meta-address in ERC6538Registry");
        console.log("  2. Sender generates stealth address from meta-address");
        console.log("  3. Sender announces via ERC5564Announcer");
        console.log("  4. Recipient scans announcements to find funds");
    }
}

/**
 * @title DeployStealthOnlyScript
 * @notice ERC5564Announcer + ERC6538Registry만 단독 배포
 */
contract DeployStealthOnlyScript is DeploymentHelper {
    function run() public {
        _initDeployment();

        console.log("=== Stealth Contracts Only Deployment ===");

        vm.startBroadcast();

        ERC5564Announcer announcer = new ERC5564Announcer();
        _setAddress(DeploymentAddresses.KEY_ANNOUNCER, address(announcer));
        console.log("ERC5564Announcer:", address(announcer));

        ERC6538Registry registry = new ERC6538Registry();
        _setAddress(DeploymentAddresses.KEY_REGISTRY, address(registry));
        console.log("ERC6538Registry:", address(registry));

        vm.stopBroadcast();

        _saveAddresses();
    }
}

/**
 * @title DeployPrivateBankOnlyScript
 * @notice PrivateBank만 단독 배포 (Announcer, Registry 주소 필요)
 */
contract DeployPrivateBankOnlyScript is DeploymentHelper {
    function run() public {
        _initDeployment();

        address announcerAddr = _getAddress(DeploymentAddresses.KEY_ANNOUNCER);
        address registryAddr = _getAddress(DeploymentAddresses.KEY_REGISTRY);

        require(announcerAddr != address(0), "ERC5564Announcer must be deployed first");
        require(registryAddr != address(0), "ERC6538Registry must be deployed first");

        console.log("=== PrivateBank Only Deployment ===");
        console.log("Using ERC5564Announcer:", announcerAddr);
        console.log("Using ERC6538Registry:", registryAddr);

        vm.startBroadcast();

        PrivateBank privateBank = new PrivateBank(announcerAddr, registryAddr);
        _setAddress(DeploymentAddresses.KEY_PRIVATE_BANK, address(privateBank));
        console.log("PrivateBank:", address(privateBank));

        vm.stopBroadcast();

        _saveAddresses();
    }
}
