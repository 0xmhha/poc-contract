// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {DeploymentHelper, DeploymentAddresses} from "../utils/DeploymentAddresses.sol";

// ERC-4337 Core
import {EntryPoint} from "../../src/erc4337-entrypoint/EntryPoint.sol";
import {IEntryPoint} from "../../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";

// Tokens
import {WKRW} from "../../src/tokens/WKRW.sol";
import {StableToken} from "../../src/tokens/StableToken.sol";

// Paymasters
import {VerifyingPaymaster} from "../../src/erc4337-paymaster/VerifyingPaymaster.sol";
import {SponsorPaymaster} from "../../src/erc4337-paymaster/SponsorPaymaster.sol";
import {ERC20Paymaster} from "../../src/erc4337-paymaster/ERC20Paymaster.sol";
import {Permit2Paymaster} from "../../src/erc4337-paymaster/Permit2Paymaster.sol";

// Dependencies
import {PriceOracle} from "../../src/defi/PriceOracle.sol";
import {IPriceOracle} from "../../src/erc4337-paymaster/interfaces/IPriceOracle.sol";

// Permit2 - Using local adapted version (0.8.28 compatible)
import {Permit2} from "../../src/permit2/Permit2.sol";
import {IPermit2} from "../../src/permit2/interfaces/IPermit2.sol";

/**
 * @title DeployERC4337Script
 * @notice ERC-4337 Account Abstraction 전체 구성요소 배포
 * @dev 배포 순서:
 *   Layer 0 (No Dependencies):
 *   - WKRW: Wrapped native token (KRW)
 *   - StableToken: USD-pegged stablecoin (USDC)
 *   - EntryPoint: UserOperation 처리의 핵심 진입점
 *   - PriceOracle: 실제 가격 오라클
 *
 *   Layer 1 (Depends on Layer 0):
 *   - VerifyingPaymaster: 서명 기반 가스 후원
 *   - SponsorPaymaster: 다양한 정책 기반 가스 후원
 *   - ERC20Paymaster: ERC20 토큰으로 가스비 지불
 *   - Permit2Paymaster: Permit2를 이용한 ERC20 가스비 지불
 *
 *   Post-Deployment Configuration:
 *   - PriceOracle: Chainlink 피드 등록 (별도 수행 필요)
 *   - ERC20Paymaster: 지원 토큰 등록
 *   - Permit2Paymaster: 지원 토큰 등록
 *
 * Usage:
 *   forge script script/deploy/DeployERC4337.s.sol:DeployERC4337Script \
 *     --rpc-url <RPC_URL> --broadcast
 *
 * Environment Variables:
 *   - ADMIN_ADDRESS: 관리자 주소 (기본값: 배포자)
 *   - VERIFYING_SIGNER: Paymaster 서명자 (기본값: 관리자)
 *   - SKIP_EXISTING: 이미 배포된 컨트랙트 스킵 (기본값: true)
 *   - PERMIT2_ADDRESS: 기존 Permit2 주소 (없으면 Permit2Paymaster 스킵)
 *   - CHAINLINK_ETH_USD: Chainlink ETH/USD 피드 주소 (선택사항)
 *   - CHAINLINK_USDC_USD: Chainlink USDC/USD 피드 주소 (선택사항)
 */
contract DeployERC4337Script is DeploymentHelper {
    function run() public {
        _initDeployment();

        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
        address verifyingSigner = vm.envOr("VERIFYING_SIGNER", admin);
        bool skipExisting = vm.envOr("SKIP_EXISTING", true);

        console.log("=== ERC-4337 Full Suite Deployment ===");
        console.log("Chain ID:", chainId);
        console.log("Admin:", admin);
        console.log("Verifying Signer:", verifyingSigner);
        console.log("Skip Existing:", skipExisting);
        console.log("");

        vm.startBroadcast();

        // ============================================
        // Layer 0: No Dependencies
        // ============================================
        console.log("--- Layer 0: Deploying Base Contracts ---");

        // 1-1. WKRW - Wrapped Native Token
        address wkrwAddr = _getAddress(DeploymentAddresses.KEY_WKRW);
        if (!skipExisting || wkrwAddr == address(0)) {
            WKRW wkrw = new WKRW();
            _setAddress(DeploymentAddresses.KEY_WKRW, address(wkrw));
            wkrwAddr = address(wkrw);
            console.log("[NEW] WKRW:", wkrwAddr);
        } else {
            console.log("[SKIP] WKRW:", wkrwAddr);
        }

        // 1-2. StableToken (USDC) - USD Pegged Stablecoin
        address stableTokenAddr = _getAddress(DeploymentAddresses.KEY_STABLE_TOKEN);
        if (!skipExisting || stableTokenAddr == address(0)) {
            StableToken stableToken = new StableToken(admin);
            _setAddress(DeploymentAddresses.KEY_STABLE_TOKEN, address(stableToken));
            stableTokenAddr = address(stableToken);
            console.log("[NEW] StableToken (USDC):", stableTokenAddr);
        } else {
            console.log("[SKIP] StableToken (USDC):", stableTokenAddr);
        }

        // 2. EntryPoint - UserOperation 처리의 핵심 진입점
        address entryPointAddr = _getAddress(DeploymentAddresses.KEY_ENTRYPOINT);
        if (!skipExisting || entryPointAddr == address(0)) {
            EntryPoint entryPoint = new EntryPoint();
            _setAddress(DeploymentAddresses.KEY_ENTRYPOINT, address(entryPoint));
            entryPointAddr = address(entryPoint);
            console.log("[NEW] EntryPoint:", entryPointAddr);
        } else {
            console.log("[SKIP] EntryPoint:", entryPointAddr);
        }

        // 3. PriceOracle - Paymaster가 사용할 가격 오라클
        address priceOracleAddr = _getAddress(DeploymentAddresses.KEY_PRICE_ORACLE);
        PriceOracle priceOracle;
        if (!skipExisting || priceOracleAddr == address(0)) {
            priceOracle = new PriceOracle();
            _setAddress(DeploymentAddresses.KEY_PRICE_ORACLE, address(priceOracle));
            priceOracleAddr = address(priceOracle);
            console.log("[NEW] PriceOracle:", priceOracleAddr);
        } else {
            priceOracle = PriceOracle(priceOracleAddr);
            console.log("[SKIP] PriceOracle:", priceOracleAddr);
        }

        // ============================================
        // Layer 1: Depends on Layer 0
        // ============================================
        console.log("\n--- Layer 1: Deploying Paymasters ---");

        // 4-1. VerifyingPaymaster - 서명 기반 가스 후원
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

        // 4-2. SponsorPaymaster - 정책 기반 가스 후원
        address sponsorPaymasterAddr = _getAddress(DeploymentAddresses.KEY_SPONSOR_PAYMASTER);
        if (!skipExisting || sponsorPaymasterAddr == address(0)) {
            SponsorPaymaster sponsorPaymaster = new SponsorPaymaster(
                IEntryPoint(entryPointAddr),
                admin,
                verifyingSigner
            );
            _setAddress(DeploymentAddresses.KEY_SPONSOR_PAYMASTER, address(sponsorPaymaster));
            console.log("[NEW] SponsorPaymaster:", address(sponsorPaymaster));
        } else {
            console.log("[SKIP] SponsorPaymaster:", sponsorPaymasterAddr);
        }

        // 4-3. ERC20Paymaster - ERC20 토큰으로 가스비 지불
        address erc20PaymasterAddr = _getAddress(DeploymentAddresses.KEY_ERC20_PAYMASTER);
        ERC20Paymaster erc20Paymaster;
        if (!skipExisting || erc20PaymasterAddr == address(0)) {
            require(priceOracleAddr != address(0), "PriceOracle required for ERC20Paymaster");
            erc20Paymaster = new ERC20Paymaster(
                IEntryPoint(entryPointAddr),
                admin,
                IPriceOracle(priceOracleAddr),
                1000 // 10% markup
            );
            _setAddress(DeploymentAddresses.KEY_ERC20_PAYMASTER, address(erc20Paymaster));
            erc20PaymasterAddr = address(erc20Paymaster);
            console.log("[NEW] ERC20Paymaster:", erc20PaymasterAddr);
        } else {
            erc20Paymaster = ERC20Paymaster(payable(erc20PaymasterAddr));
            console.log("[SKIP] ERC20Paymaster:", erc20PaymasterAddr);
        }

        // 4-4. Permit2 - Uniswap Permit2 컨트랙트
        address permit2Addr = vm.envOr("PERMIT2_ADDRESS", _getAddress(DeploymentAddresses.KEY_PERMIT2));
        if (!skipExisting || permit2Addr == address(0)) {
            Permit2 permit2 = new Permit2();
            _setAddress(DeploymentAddresses.KEY_PERMIT2, address(permit2));
            permit2Addr = address(permit2);
            console.log("[NEW] Permit2:", permit2Addr);
        } else {
            console.log("[SKIP] Permit2:", permit2Addr);
        }

        // 4-5. Permit2Paymaster - Permit2를 이용한 ERC20 가스비 지불
        address permit2PaymasterAddr = _getAddress(DeploymentAddresses.KEY_PERMIT2_PAYMASTER);
        Permit2Paymaster permit2Paymaster;

        if (!skipExisting || permit2PaymasterAddr == address(0)) {
            require(priceOracleAddr != address(0), "PriceOracle required for Permit2Paymaster");
            require(permit2Addr != address(0), "Permit2 required for Permit2Paymaster");
            permit2Paymaster = new Permit2Paymaster(
                IEntryPoint(entryPointAddr),
                admin,
                IPermit2(permit2Addr),
                IPriceOracle(priceOracleAddr),
                1000 // 10% markup
            );
            _setAddress(DeploymentAddresses.KEY_PERMIT2_PAYMASTER, address(permit2Paymaster));
            permit2PaymasterAddr = address(permit2Paymaster);
            console.log("[NEW] Permit2Paymaster:", permit2PaymasterAddr);
        } else {
            permit2Paymaster = Permit2Paymaster(payable(permit2PaymasterAddr));
            console.log("[SKIP] Permit2Paymaster:", permit2PaymasterAddr);
        }

        // ============================================
        // Post-Deployment Configuration
        // ============================================
        console.log("\n--- Post-Deployment Configuration ---");

        // ERC20Paymaster에 지원 토큰 등록
        if (erc20PaymasterAddr != address(0) && stableTokenAddr != address(0)) {
            // Check if already supported to avoid redundant calls
            if (!erc20Paymaster.supportedTokens(stableTokenAddr)) {
                erc20Paymaster.setSupportedToken(stableTokenAddr, true);
                console.log("[CONFIG] ERC20Paymaster: StableToken supported");
            }
        }

        // Permit2Paymaster에 지원 토큰 등록
        if (permit2PaymasterAddr != address(0) && stableTokenAddr != address(0)) {
            if (!permit2Paymaster.supportedTokens(stableTokenAddr)) {
                permit2Paymaster.setSupportedToken(stableTokenAddr, true);
                console.log("[CONFIG] Permit2Paymaster: StableToken supported");
            }
        }

        vm.stopBroadcast();

        _saveAddresses();

        console.log("");
        console.log("=== ERC-4337 Deployment Complete ===");
        console.log("Addresses saved to:", _getDeploymentPath());
        console.log("");
        console.log("=== POST-DEPLOYMENT CHECKLIST ===");
        console.log("1. Register Chainlink price feeds on PriceOracle:");
        console.log("   - priceOracle.setChainlinkFeed(address(0), ETH_USD_FEED)");
        console.log("   - priceOracle.setChainlinkFeed(stableToken, USDC_USD_FEED)");
        console.log("2. Fund Paymasters with ETH:");
        console.log("   - entryPoint.depositTo{value: amount}(paymasterAddress)");
        console.log("3. (Optional) Configure SponsorPaymaster policies");
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

/**
 * @title DeployTokensOnlyScript
 * @notice WKRW와 StableToken만 단독 배포
 */
contract DeployTokensOnlyScript is DeploymentHelper {
    function run() public {
        _initDeployment();

        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);

        console.log("=== Tokens Only Deployment ===");
        console.log("Admin:", admin);

        vm.startBroadcast();

        // WKRW
        WKRW wkrw = new WKRW();
        _setAddress(DeploymentAddresses.KEY_WKRW, address(wkrw));
        console.log("WKRW:", address(wkrw));

        // StableToken (USDC)
        StableToken stableToken = new StableToken(admin);
        _setAddress(DeploymentAddresses.KEY_STABLE_TOKEN, address(stableToken));
        console.log("StableToken (USDC):", address(stableToken));

        vm.stopBroadcast();

        _saveAddresses();
    }
}

/**
 * @title ConfigurePriceOracleScript
 * @notice PriceOracle에 Chainlink 피드 등록
 * @dev Environment Variables:
 *   - CHAINLINK_ETH_USD: ETH/USD 피드 주소
 *   - CHAINLINK_USDC_USD: USDC/USD 피드 주소
 */
contract ConfigurePriceOracleScript is DeploymentHelper {
    function run() public {
        _initDeployment();

        address priceOracleAddr = _getAddress(DeploymentAddresses.KEY_PRICE_ORACLE);
        require(priceOracleAddr != address(0), "PriceOracle not deployed");

        address stableTokenAddr = _getAddress(DeploymentAddresses.KEY_STABLE_TOKEN);

        address ethUsdFeed = vm.envOr("CHAINLINK_ETH_USD", address(0));
        address usdcUsdFeed = vm.envOr("CHAINLINK_USDC_USD", address(0));

        console.log("=== Configure PriceOracle ===");
        console.log("PriceOracle:", priceOracleAddr);

        vm.startBroadcast();

        PriceOracle priceOracle = PriceOracle(priceOracleAddr);

        // ETH/USD 피드 등록
        if (ethUsdFeed != address(0)) {
            priceOracle.setChainlinkFeed(address(0), ethUsdFeed);
            console.log("[CONFIG] ETH/USD feed:", ethUsdFeed);
        } else {
            console.log("[SKIP] ETH/USD feed: CHAINLINK_ETH_USD not set");
        }

        // USDC/USD 피드 등록
        if (usdcUsdFeed != address(0) && stableTokenAddr != address(0)) {
            priceOracle.setChainlinkFeed(stableTokenAddr, usdcUsdFeed);
            console.log("[CONFIG] USDC/USD feed:", usdcUsdFeed);
        } else {
            console.log("[SKIP] USDC/USD feed: CHAINLINK_USDC_USD or StableToken not set");
        }

        vm.stopBroadcast();

        console.log("=== PriceOracle Configuration Complete ===");
    }
}

/**
 * @title FundPaymastersScript
 * @notice Paymaster에 ETH 펀딩
 * @dev Environment Variables:
 *   - FUND_AMOUNT: 펀딩할 ETH 양 (기본값: 1 ether)
 */
contract FundPaymastersScript is DeploymentHelper {
    function run() public {
        _initDeployment();

        address entryPointAddr = _getAddress(DeploymentAddresses.KEY_ENTRYPOINT);
        require(entryPointAddr != address(0), "EntryPoint not deployed");

        uint256 fundAmount = vm.envOr("FUND_AMOUNT", uint256(1 ether));

        console.log("=== Fund Paymasters ===");
        console.log("EntryPoint:", entryPointAddr);
        console.log("Fund Amount:", fundAmount);

        vm.startBroadcast();

        IEntryPoint entryPoint = IEntryPoint(entryPointAddr);

        // VerifyingPaymaster
        address verifyingPaymaster = _getAddress(DeploymentAddresses.KEY_VERIFYING_PAYMASTER);
        if (verifyingPaymaster != address(0)) {
            entryPoint.depositTo{value: fundAmount}(verifyingPaymaster);
            console.log("[FUNDED] VerifyingPaymaster:", fundAmount);
        }

        // SponsorPaymaster
        address sponsorPaymaster = _getAddress(DeploymentAddresses.KEY_SPONSOR_PAYMASTER);
        if (sponsorPaymaster != address(0)) {
            entryPoint.depositTo{value: fundAmount}(sponsorPaymaster);
            console.log("[FUNDED] SponsorPaymaster:", fundAmount);
        }

        // ERC20Paymaster
        address erc20Paymaster = _getAddress(DeploymentAddresses.KEY_ERC20_PAYMASTER);
        if (erc20Paymaster != address(0)) {
            entryPoint.depositTo{value: fundAmount}(erc20Paymaster);
            console.log("[FUNDED] ERC20Paymaster:", fundAmount);
        }

        // Permit2Paymaster
        address permit2Paymaster = _getAddress(DeploymentAddresses.KEY_PERMIT2_PAYMASTER);
        if (permit2Paymaster != address(0)) {
            entryPoint.depositTo{value: fundAmount}(permit2Paymaster);
            console.log("[FUNDED] Permit2Paymaster:", fundAmount);
        }

        vm.stopBroadcast();

        console.log("=== Paymaster Funding Complete ===");
    }
}
