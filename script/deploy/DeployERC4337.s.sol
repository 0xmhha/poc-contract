// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {DeploymentHelper, DeploymentAddresses} from "../utils/DeploymentAddresses.sol";

// ERC-4337 Core
import {EntryPoint} from "../../src/erc4337-entrypoint/EntryPoint.sol";
import {IEntryPoint} from "../../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";

// Paymasters
import {VerifyingPaymaster} from "../../src/erc4337-paymaster/VerifyingPaymaster.sol";
import {ERC20Paymaster} from "../../src/erc4337-paymaster/ERC20Paymaster.sol";
import {IPriceOracle} from "../../src/erc4337-paymaster/interfaces/IPriceOracle.sol";

/**
 * @title DeployERC4337Script
 * @notice ERC-4337 Account Abstraction 컨트랙트 배포
 * @dev 배포되는 컨트랙트:
 *   - EntryPoint: UserOperation 처리의 핵심 진입점
 *   - VerifyingPaymaster: 서명 기반 가스 후원
 *   - ERC20Paymaster: ERC20 토큰으로 가스비 지불
 *
 * 의존성:
 *   - ERC20Paymaster는 PriceOracle이 필요 (선택적)
 *
 * Usage:
 *   forge script script/deploy/DeployERC4337.s.sol:DeployERC4337Script \
 *     --rpc-url http://127.0.0.1:8545 --broadcast
 *
 * Environment Variables:
 *   - ADMIN_ADDRESS: 관리자 주소 (기본값: 배포자)
 *   - VERIFYING_SIGNER: Paymaster 서명자 (기본값: 관리자)
 *   - SKIP_EXISTING: 이미 배포된 컨트랙트 스킵 (기본값: true)
 */
contract DeployERC4337Script is DeploymentHelper {
    function run() public {
        _initDeployment();

        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
        address verifyingSigner = vm.envOr("VERIFYING_SIGNER", admin);
        bool skipExisting = vm.envOr("SKIP_EXISTING", true);

        console.log("=== ERC-4337 Account Abstraction Deployment ===");
        console.log("Chain ID:", chainId);
        console.log("Admin:", admin);
        console.log("Verifying Signer:", verifyingSigner);
        console.log("Skip Existing:", skipExisting);
        console.log("");

        vm.startBroadcast();

        // 1. EntryPoint - UserOperation 처리의 핵심 진입점
        address entryPointAddr = _getAddress(DeploymentAddresses.KEY_ENTRYPOINT);
        if (!skipExisting || entryPointAddr == address(0)) {
            EntryPoint entryPoint = new EntryPoint();
            _setAddress(DeploymentAddresses.KEY_ENTRYPOINT, address(entryPoint));
            entryPointAddr = address(entryPoint);
            console.log("[NEW] EntryPoint:", entryPointAddr);
        } else {
            console.log("[SKIP] EntryPoint:", entryPointAddr);
        }

        // 2. VerifyingPaymaster - 서명 기반 가스 후원
        address verifyingPaymasterAddr = _getAddress(DeploymentAddresses.KEY_VERIFYING_PAYMASTER);
        if (!skipExisting || verifyingPaymasterAddr == address(0)) {
            VerifyingPaymaster verifyingPaymaster = new VerifyingPaymaster(
                IEntryPoint(entryPointAddr),
                admin,
                verifyingSigner
            );
            _setAddress(DeploymentAddresses.KEY_VERIFYING_PAYMASTER, address(verifyingPaymaster));
            console.log("[NEW] VerifyingPaymaster:", address(verifyingPaymaster));
        } else {
            console.log("[SKIP] VerifyingPaymaster:", verifyingPaymasterAddr);
        }

        // 3. ERC20Paymaster - ERC20 토큰으로 가스비 지불 (PriceOracle 필요)
        address erc20PaymasterAddr = _getAddress(DeploymentAddresses.KEY_ERC20_PAYMASTER);
        address priceOracleAddr = _getAddress(DeploymentAddresses.KEY_PRICE_ORACLE);

        if (!skipExisting || erc20PaymasterAddr == address(0)) {
            if (priceOracleAddr != address(0)) {
                ERC20Paymaster erc20Paymaster = new ERC20Paymaster(
                    IEntryPoint(entryPointAddr),
                    admin,
                    IPriceOracle(priceOracleAddr),
                    1000 // 10% markup
                );
                _setAddress(DeploymentAddresses.KEY_ERC20_PAYMASTER, address(erc20Paymaster));
                console.log("[NEW] ERC20Paymaster:", address(erc20Paymaster));
            } else {
                console.log("[SKIP] ERC20Paymaster: PriceOracle not deployed");
            }
        } else {
            console.log("[SKIP] ERC20Paymaster:", erc20PaymasterAddr);
        }

        vm.stopBroadcast();

        _saveAddresses();

        console.log("");
        console.log("=== ERC-4337 Deployment Complete ===");
        console.log("Addresses saved to:", _getDeploymentPath());
    }
}

/**
 * @title DeployEntryPointOnlyScript
 * @notice EntryPoint만 단독 배포
 */
contract DeployEntryPointOnlyScript is DeploymentHelper {
    function run() public {
        _initDeployment();

        console.log("=== EntryPoint Only Deployment ===");

        vm.startBroadcast();

        EntryPoint entryPoint = new EntryPoint();
        _setAddress(DeploymentAddresses.KEY_ENTRYPOINT, address(entryPoint));
        console.log("EntryPoint:", address(entryPoint));

        vm.stopBroadcast();

        _saveAddresses();
    }
}
