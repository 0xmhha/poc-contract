// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IPerpetualEngine } from "./interfaces/IPerpetualEngine.sol";
import { IPositionManager } from "./interfaces/IPositionManager.sol";
import { IMarginManager } from "./interfaces/IMarginManager.sol";
import { IOrderManager } from "./interfaces/IOrderManager.sol";
import { PerpetualTypes } from "./libraries/PerpetualTypes.sol";
import { PerpetualMath } from "./libraries/PerpetualMath.sol";
import { PerpetualErrors } from "./libraries/PerpetualErrors.sol";
import { PerpetualEvents } from "./libraries/PerpetualEvents.sol";
import { Constants } from "../common/libraries/Constants.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title PerpetualEngine
 * @author StableNet Team
 * @notice 무기한 선물 거래 메인 엔진 컨트랙트
 * @dev
 * - 마켓 관리 (생성, 상태 변경, 설정 업데이트)
 * - 거래 진입점 (포지션 오픈/종료, 주문 생성/취소)
 * - 컴포넌트 통합 (Position, Margin, Order, Liquidator, InsuranceFund, ADL)
 * @custom:status TESTNET ONLY. Reference implementation for indexer trading venues; not audited.
 *      Trading requires a configured mark-price oracle; settlement remains testnet-only.
 */
contract PerpetualEngine is IPerpetualEngine, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using PerpetualMath for uint256;

    // ============ Constants ============

    uint256 private constant PRECISION = Constants.PRECISION;
    uint256 private constant BPS_PRECISION = Constants.BPS_PRECISION;

    /// @notice 최대 마켓 수
    uint32 public constant MAX_MARKETS = 100;

    /// @notice 기본 레버리지
    uint8 public constant DEFAULT_LEVERAGE = 10;

    // ============ State Variables ============

    /// @notice 결제 토큰 (USDC 등)
    IERC20 public immutable collateralToken;

    /// @notice 마켓 저장소
    mapping(uint32 => MarketData) private _markets;

    /// @notice 마켓 ID 목록
    uint32[] private _marketIds;

    /// @notice 다음 마켓 ID
    uint32 private _nextMarketId;

    /// @notice 트레이더별 기본 레버리지
    mapping(address => mapping(uint32 => uint8)) private _traderLeverages;

    /// @notice 마켓별 오라클 주소
    mapping(uint32 => OracleConfig) private _oracleConfigs;

    /// @notice 관리자 주소
    address private _admin;

    /// @notice 컴포넌트 주소
    Components private _components;

    /// @notice 마켓 데이터 (확장 구조)
    struct MarketData {
        address baseToken; // 기초 자산 주소 (NFT 표현용)
        address quoteToken; // 결제 토큰 주소
        string baseAsset; // 기초 자산 이름 (예: "BTC")
        string quoteAsset; // 견적 자산 이름 (예: "USDT")
        uint64 createdAt; // 생성 시간
        PerpetualTypes.MarketStatus status; // 마켓 상태
        PerpetualTypes.MarketConfig config; // 마켓 설정
        PerpetualTypes.MarketStats stats; // 마켓 통계
        bool exists; // 존재 여부
    }

    /// @notice 오라클 설정
    struct OracleConfig {
        address indexOracle;
        address markOracle;
    }

    /// @notice 컴포넌트 주소들
    struct Components {
        address positionManager;
        address marginManager;
        address orderManager;
        address liquidator;
        address insuranceFund;
        address adlEngine;
        address fundingRate;
    }

    // ============ Modifiers ============

    modifier onlyAdmin() {
        if (msg.sender != _admin) {
            revert PerpetualErrors.Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyExistingMarket(uint32 marketId) {
        if (!_markets[marketId].exists) {
            revert PerpetualErrors.MarketNotFound(marketId);
        }
        _;
    }

    modifier marketActive(uint32 marketId) {
        MarketData storage market = _markets[marketId];
        if (!market.exists) {
            revert PerpetualErrors.MarketNotFound(marketId);
        }
        if (market.status != PerpetualTypes.MarketStatus.Active) {
            revert PerpetualErrors.MarketNotActive(marketId);
        }
        _;
    }

    // ============ Constructor ============

    /**
     * @notice 컨트랙트 초기화
     * @param admin 관리자 주소
     * @param collateral 결제 토큰 주소
     */
    constructor(address admin, address collateral) {
        if (admin == address(0) || collateral == address(0)) {
            revert PerpetualErrors.ZeroAddress();
        }

        _admin = admin;
        collateralToken = IERC20(collateral);
        _nextMarketId = 1;
    }

    // ============ View Functions ============

    /// @inheritdoc IPerpetualEngine
    function getMarket(uint32 marketId)
        external
        view
        override
        onlyExistingMarket(marketId)
        returns (PerpetualTypes.Market memory market)
    {
        MarketData storage data = _markets[marketId];
        market = PerpetualTypes.Market({
            marketId: marketId,
            baseToken: data.baseToken,
            quoteToken: data.quoteToken,
            createdAt: data.createdAt,
            status: data.status,
            config: data.config,
            stats: data.stats
        });
    }

    /// @inheritdoc IPerpetualEngine
    function getMarketSymbols(uint32 marketId)
        external
        view
        override
        onlyExistingMarket(marketId)
        returns (string memory baseAsset, string memory quoteAsset)
    {
        MarketData storage data = _markets[marketId];
        return (data.baseAsset, data.quoteAsset);
    }

    /// @inheritdoc IPerpetualEngine
    function getMarketConfig(uint32 marketId)
        external
        view
        override
        onlyExistingMarket(marketId)
        returns (PerpetualTypes.MarketConfig memory config)
    {
        return _markets[marketId].config;
    }

    /// @inheritdoc IPerpetualEngine
    function getMarketStats(uint32 marketId)
        external
        view
        override
        onlyExistingMarket(marketId)
        returns (PerpetualTypes.MarketStats memory stats)
    {
        return _markets[marketId].stats;
    }

    /// @inheritdoc IPerpetualEngine
    function marketExists(uint32 marketId) external view override returns (bool exists) {
        return _markets[marketId].exists;
    }

    /// @inheritdoc IPerpetualEngine
    function isMarketActive(uint32 marketId) external view override returns (bool isActive) {
        MarketData storage market = _markets[marketId];
        return market.exists && market.status == PerpetualTypes.MarketStatus.Active;
    }

    /// @inheritdoc IPerpetualEngine
    function getAllMarketIds() external view override returns (uint32[] memory marketIds) {
        return _marketIds;
    }

    /// @inheritdoc IPerpetualEngine
    function getMarketCount() external view override returns (uint256 count) {
        return _marketIds.length;
    }

    /// @inheritdoc IPerpetualEngine
    function getComponents()
        external
        view
        override
        returns (
            address positionManager,
            address marginManager,
            address orderManager,
            address liquidator,
            address insuranceFund,
            address adlEngine
        )
    {
        return (
            _components.positionManager,
            _components.marginManager,
            _components.orderManager,
            _components.liquidator,
            _components.insuranceFund,
            _components.adlEngine
        );
    }

    // ============ Trading Functions ============

    /// @inheritdoc IPerpetualEngine
    function depositMargin(uint256 amount) external override nonReentrant whenNotPaused {
        if (amount == 0) {
            revert PerpetualErrors.ZeroAmount();
        }

        // 토큰 전송
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        collateralToken.forceApprove(_components.marginManager, amount);

        // MarginManager에 입금 처리
        IMarginManager(_components.marginManager).depositMargin(msg.sender, amount);
    }

    /// @inheritdoc IPerpetualEngine
    function withdrawMargin(uint256 amount) external override nonReentrant whenNotPaused {
        if (amount == 0) {
            revert PerpetualErrors.ZeroAmount();
        }

        // MarginManager에서 출금 처리
        IMarginManager(_components.marginManager).withdrawMargin(msg.sender, amount);
    }

    /// @inheritdoc IPerpetualEngine
    function openMarketPosition(uint32 marketId, PerpetualTypes.PositionSide side, uint128 size, uint128 maxSlippage)
        external
        override
        nonReentrant
        whenNotPaused
        marketActive(marketId)
        returns (bytes32 positionKey, uint128 fillPrice)
    {
        if (size == 0) {
            revert PerpetualErrors.ZeroSize();
        }

        // 시장가 주문 실행
        (fillPrice,) =
            IOrderManager(_components.orderManager).executeMarketOrder(msg.sender, marketId, side, size, maxSlippage);

        // 레버리지 조회
        uint8 leverage = _traderLeverages[msg.sender][marketId];
        if (leverage == 0) {
            leverage = DEFAULT_LEVERAGE;
        }

        // 필요 마진 계산
        uint256 requiredMargin = PerpetualMath.calculateRequiredMargin(size, fillPrice, leverage);
        if (requiredMargin > type(uint128).max) revert PerpetualErrors.InvalidParameter("margin overflow");

        // 마진 락
        IMarginManager(_components.marginManager).lockMargin(msg.sender, requiredMargin);

        // 포지션 오픈
        positionKey = IPositionManager(_components.positionManager)
            .openPosition(msg.sender, marketId, side, size, uint128(requiredMargin), leverage, fillPrice);

        return (positionKey, fillPrice);
    }

    /// @inheritdoc IPerpetualEngine
    function placeLimitOrder(PerpetualTypes.OrderParams calldata params)
        external
        override
        nonReentrant
        whenNotPaused
        marketActive(params.marketId)
        returns (bytes32 orderId)
    {
        // 주문 생성
        orderId = IOrderManager(_components.orderManager).createOrder(msg.sender, params);

        return orderId;
    }

    /// @inheritdoc IPerpetualEngine
    function closePosition(bytes32 positionKey, uint128 maxSlippage)
        external
        override
        nonReentrant
        whenNotPaused
        returns (int256 realizedPnL)
    {
        // 포지션 조회
        PerpetualTypes.Position memory position = IPositionManager(_components.positionManager).getPosition(positionKey);

        if (position.trader != msg.sender) {
            revert PerpetualErrors.Unauthorized(msg.sender);
        }

        // 현재 가격 조회 및 포지션 종료
        uint128 exitPrice = _getMarketPrice(position.marketId, position.side, true);

        // 슬리피지 확인
        _checkSlippage(position.side, exitPrice, 0, maxSlippage, true);

        // 포지션 종료
        realizedPnL = IPositionManager(_components.positionManager).closePosition(positionKey, exitPrice);

        // 마진 언락
        IMarginManager(_components.marginManager).unlockMargin(msg.sender, position.margin);

        // PnL 정산
        IMarginManager(_components.marginManager).realizePnL(msg.sender, realizedPnL);

        return realizedPnL;
    }

    /// @inheritdoc IPerpetualEngine
    function reducePosition(bytes32 positionKey, uint128 reduceSize, uint128 maxSlippage)
        external
        override
        nonReentrant
        whenNotPaused
        returns (int256 realizedPnL)
    {
        // 포지션 조회
        PerpetualTypes.Position memory position = IPositionManager(_components.positionManager).getPosition(positionKey);

        if (position.trader != msg.sender) {
            revert PerpetualErrors.Unauthorized(msg.sender);
        }

        // 현재 가격 조회
        uint128 exitPrice = _getMarketPrice(position.marketId, position.side, true);

        // 슬리피지 확인
        _checkSlippage(position.side, exitPrice, 0, maxSlippage, true);

        // 포지션 감소
        realizedPnL = IPositionManager(_components.positionManager).decreasePosition(positionKey, reduceSize, exitPrice);

        // 비례 마진 언락
        uint256 marginToUnlock = PerpetualMath.mulDiv(position.margin, reduceSize, position.size);
        IMarginManager(_components.marginManager).unlockMargin(msg.sender, marginToUnlock);

        // PnL 정산
        IMarginManager(_components.marginManager).realizePnL(msg.sender, realizedPnL);

        return realizedPnL;
    }

    /// @inheritdoc IPerpetualEngine
    function cancelOrder(bytes32 orderId) external override nonReentrant whenNotPaused {
        IOrderManager(_components.orderManager).cancelOrder(orderId);
    }

    /// @inheritdoc IPerpetualEngine
    function cancelAllOrders(uint32 marketId) external override nonReentrant whenNotPaused {
        bytes32[] memory orders = IOrderManager(_components.orderManager).getTraderOpenOrders(msg.sender);

        for (uint256 i = 0; i < orders.length; i++) {
            PerpetualTypes.Order memory order = IOrderManager(_components.orderManager).getOrder(orders[i]);
            if (marketId == 0 || order.marketId == marketId) {
                try IOrderManager(_components.orderManager).cancelOrder(orders[i]) { } catch { }
            }
        }
    }

    /// @inheritdoc IPerpetualEngine
    function addPositionMargin(bytes32 positionKey, uint128 addMargin) external override nonReentrant whenNotPaused {
        // 포지션 조회
        PerpetualTypes.Position memory position = IPositionManager(_components.positionManager).getPosition(positionKey);

        if (position.trader != msg.sender) {
            revert PerpetualErrors.Unauthorized(msg.sender);
        }

        // 마진 추가
        IPositionManager(_components.positionManager).addMargin(positionKey, addMargin);
        IMarginManager(_components.marginManager).lockMargin(msg.sender, addMargin);
    }

    /// @inheritdoc IPerpetualEngine
    function removePositionMargin(bytes32 positionKey, uint128 removeMargin)
        external
        override
        nonReentrant
        whenNotPaused
    {
        // 포지션 조회
        PerpetualTypes.Position memory position = IPositionManager(_components.positionManager).getPosition(positionKey);

        if (position.trader != msg.sender) {
            revert PerpetualErrors.Unauthorized(msg.sender);
        }

        // 마진 제거
        IPositionManager(_components.positionManager).removeMargin(positionKey, removeMargin);
        IMarginManager(_components.marginManager).unlockMargin(msg.sender, removeMargin);
    }

    /// @inheritdoc IPerpetualEngine
    function setMarginMode(uint32 marketId, PerpetualTypes.MarginMode mode)
        external
        override
        nonReentrant
        whenNotPaused
        onlyExistingMarket(marketId)
    {
        if (mode != PerpetualTypes.MarginMode.Isolated) revert PerpetualErrors.InvalidMarginMode(mode);
        IMarginManager(_components.marginManager).setMarginMode(msg.sender, marketId, mode);
    }

    /// @inheritdoc IPerpetualEngine
    function setLeverage(uint32 marketId, uint8 leverage) external override onlyExistingMarket(marketId) {
        PerpetualTypes.MarketConfig storage config = _markets[marketId].config;

        if (leverage == 0 || leverage > config.maxLeverage) {
            revert PerpetualErrors.InvalidLeverage(leverage, 1, config.maxLeverage);
        }

        _traderLeverages[msg.sender][marketId] = leverage;
    }

    // ============ Admin Functions ============

    /// @inheritdoc IPerpetualEngine
    function createMarket(
        string calldata baseAsset,
        string calldata quoteAsset,
        PerpetualTypes.MarketConfig calldata config
    ) external override onlyAdmin returns (uint32 marketId) {
        if (_marketIds.length >= MAX_MARKETS) {
            revert PerpetualErrors.InvalidParameter("max markets reached");
        }

        marketId = _nextMarketId++;

        MarketData storage market = _markets[marketId];
        market.baseAsset = baseAsset;
        market.quoteAsset = quoteAsset;
        market.quoteToken = address(collateralToken);
        market.createdAt = uint64(block.timestamp);
        market.status = PerpetualTypes.MarketStatus.Active;
        market.config = config;
        market.exists = true;

        _marketIds.push(marketId);
        if (_components.positionManager != address(0)) {
            IPositionManager(_components.positionManager).setMarketConfig(marketId, config);
        }

        emit PerpetualEvents.MarketCreated(marketId, address(0), address(collateralToken), config.maxLeverage);

        return marketId;
    }

    /// @inheritdoc IPerpetualEngine
    function setMarketStatus(uint32 marketId, PerpetualTypes.MarketStatus status)
        external
        override
        onlyAdmin
        onlyExistingMarket(marketId)
    {
        MarketData storage market = _markets[marketId];
        PerpetualTypes.MarketStatus oldStatus = market.status;
        market.status = status;

        emit PerpetualEvents.MarketStatusChanged(marketId, oldStatus, status);
    }

    /// @inheritdoc IPerpetualEngine
    function updateMarketConfig(uint32 marketId, PerpetualTypes.MarketConfig calldata config)
        external
        override
        onlyAdmin
        onlyExistingMarket(marketId)
    {
        _markets[marketId].config = config;
        if (_components.positionManager != address(0)) {
            IPositionManager(_components.positionManager).setMarketConfig(marketId, config);
        }
    }

    /// @inheritdoc IPerpetualEngine
    function setComponents(
        address positionManager,
        address marginManager,
        address orderManager,
        address liquidator,
        address insuranceFund,
        address adlEngine
    ) external override onlyAdmin {
        _components.positionManager = positionManager;
        _components.marginManager = marginManager;
        _components.orderManager = orderManager;
        _components.liquidator = liquidator;
        _components.insuranceFund = insuranceFund;
        _components.adlEngine = adlEngine;
        for (uint256 i = 0; i < _marketIds.length; i++) {
            uint32 marketId = _marketIds[i];
            if (positionManager != address(0)) {
                IPositionManager(positionManager).setMarketConfig(marketId, _markets[marketId].config);
                if (_oracleConfigs[marketId].markOracle != address(0)) {
                    IPositionManager(positionManager).setMarketOracle(marketId, _oracleConfigs[marketId].markOracle);
                }
            }
            if (orderManager != address(0) && _oracleConfigs[marketId].markOracle != address(0)) {
                IOrderManager(orderManager).setMarketPriceOracle(marketId, _oracleConfigs[marketId].markOracle);
            }
        }
    }

    /// @inheritdoc IPerpetualEngine
    function setOracles(uint32 marketId, address indexOracle, address markOracle)
        external
        override
        onlyAdmin
        onlyExistingMarket(marketId)
    {
        if (markOracle == address(0)) revert PerpetualErrors.ZeroAddress();
        _oracleConfigs[marketId] = OracleConfig({ indexOracle: indexOracle, markOracle: markOracle });
        IPositionManager(_components.positionManager).setMarketOracle(marketId, markOracle);
        IOrderManager(_components.orderManager).setMarketPriceOracle(marketId, markOracle);
    }

    /// @inheritdoc IPerpetualEngine
    function emergencyPause() external override onlyAdmin {
        _pause();
        emit PerpetualEvents.SystemPaused(msg.sender);
    }

    /// @inheritdoc IPerpetualEngine
    function emergencyUnpause() external override onlyAdmin {
        _unpause();
        emit PerpetualEvents.SystemUnpaused(msg.sender);
    }

    /// @inheritdoc IPerpetualEngine
    function pauseTrading(uint32 marketId) external override onlyAdmin onlyExistingMarket(marketId) {
        _markets[marketId].status = PerpetualTypes.MarketStatus.Paused;
        emit PerpetualEvents.MarketStatusChanged(
            marketId, PerpetualTypes.MarketStatus.Active, PerpetualTypes.MarketStatus.Paused
        );
    }

    /// @inheritdoc IPerpetualEngine
    function resumeTrading(uint32 marketId) external override onlyAdmin onlyExistingMarket(marketId) {
        _markets[marketId].status = PerpetualTypes.MarketStatus.Active;
        emit PerpetualEvents.MarketStatusChanged(
            marketId, PerpetualTypes.MarketStatus.Paused, PerpetualTypes.MarketStatus.Active
        );
    }

    /**
     * @notice FundingRate 컴포넌트 설정
     * @param fundingRate FundingRate 주소
     */
    function setFundingRate(address fundingRate) external onlyAdmin {
        if (fundingRate == address(0)) {
            revert PerpetualErrors.ZeroAddress();
        }
        _components.fundingRate = fundingRate;
    }

    // ============ Internal Functions ============

    /**
     * @notice 시장 가격 조회
     * @param marketId 마켓 ID
     * @return price 가격
     */
    function _getMarketPrice(uint32 marketId, PerpetualTypes.PositionSide, bool) internal view returns (uint128 price) {
        price = IPositionManager(_components.positionManager).getMarkPrice(marketId);
    }

    /**
     * @notice 슬리피지 확인
     * @param side 포지션 방향
     * @param actualPrice 실제 가격
     * @param expectedPrice 예상 가격 (0이면 확인 안함)
     * @param maxSlippage 최대 슬리피지 (BPS)
     * @param isClose 종료 여부
     */
    function _checkSlippage(
        PerpetualTypes.PositionSide side,
        uint128 actualPrice,
        uint128 expectedPrice,
        uint128 maxSlippage,
        bool isClose
    ) internal pure {
        if (expectedPrice == 0 || maxSlippage == 0) {
            return;
        }

        uint256 slippage;
        bool isUnfavorable;

        if (isClose) {
            // 종료: 롱은 낮은 가격이 불리, 숏은 높은 가격이 불리
            if (side == PerpetualTypes.PositionSide.Long) {
                isUnfavorable = actualPrice < expectedPrice;
                slippage =
                    isUnfavorable ? PerpetualMath.mulDiv(expectedPrice - actualPrice, BPS_PRECISION, expectedPrice) : 0;
            } else {
                isUnfavorable = actualPrice > expectedPrice;
                slippage =
                    isUnfavorable ? PerpetualMath.mulDiv(actualPrice - expectedPrice, BPS_PRECISION, expectedPrice) : 0;
            }
        } else {
            // 오픈: 롱은 높은 가격이 불리, 숏은 낮은 가격이 불리
            if (side == PerpetualTypes.PositionSide.Long) {
                isUnfavorable = actualPrice > expectedPrice;
                slippage =
                    isUnfavorable ? PerpetualMath.mulDiv(actualPrice - expectedPrice, BPS_PRECISION, expectedPrice) : 0;
            } else {
                isUnfavorable = actualPrice < expectedPrice;
                slippage =
                    isUnfavorable ? PerpetualMath.mulDiv(expectedPrice - actualPrice, BPS_PRECISION, expectedPrice) : 0;
            }
        }

        if (slippage > maxSlippage) {
            revert PerpetualErrors.SlippageExceeded(expectedPrice, actualPrice, maxSlippage);
        }
    }
}
