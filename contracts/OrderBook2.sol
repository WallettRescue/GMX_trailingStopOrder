// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import "../libraries/math/SafeMath.sol";
import "../libraries/token/IERC20.sol";
import "../tokens/interfaces/IWETH.sol";
import "../libraries/token/SafeERC20.sol";
import "../libraries/utils/Address.sol";
import "../libraries/utils/ReentrancyGuard.sol";

import "./interfaces/IRouter.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IOrderBook2.sol";

contract OrderBook2 is ReentrancyGuard, IOrderBook2 {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address payable;

    uint256 public constant PRICE_PRECISION = 1e30;
    uint256 public constant USDF_PRECISION = 1e18;

    struct TrailingStopOrder {
        address account;
        address collateralToken;
        uint256 collateralDelta;
        address indexToken;
        uint256 sizeDelta;
        bool isLong;
        uint256 triggerPrice;
        bool triggerAboveThreshold;
        uint256 executionFee;
        uint256 trailingBPS;
    }

    mapping(address => mapping(uint256 => TrailingStopOrder))
        public trailingStopOrders;
    mapping(address => uint256) public trailingStopOrdersIndex;

    address public gov;
    address public weth;
    address public usdf;
    address public router;
    address public vault;
    uint256 public minExecutionFee;
    uint256 public minPurchaseTokenAmountUsd;
    bool public isInitialized = false;

    address public fastPriceFeed;

    event CreateTrailingStopOrder(
        address indexed account,
        uint256 orderIndex,
        address collateralToken,
        uint256 collateralDelta,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold,
        uint256 executionFee,
        uint256 trailingBPS
    );
    event ExecuteTrailingStopOrder(
        address indexed account,
        uint256 orderIndex,
        address collateralToken,
        uint256 collateralDelta,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold,
        uint256 executionFee,
        uint256 executionPrice,
        uint256 trailingBPS
    );
    event UpdateTrailingStopOrder(
        address indexed account,
        uint256 orderIndex,
        address collateralToken,
        uint256 collateralDelta,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold,
        uint256 trailingBPS
    );
    event CancelTrailingStopOrder(
        address indexed account,
        uint256 orderIndex,
        address collateralToken,
        uint256 collateralDelta,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold,
        uint256 executionFee,
        uint256 trailingBPS
    );

    event Initialize(
        address router,
        address vault,
        address weth,
        address usdf,
        uint256 minExecutionFee,
        uint256 minPurchaseTokenAmountUsd,
        address fastPriceFeed
    );
    event UpdateMinExecutionFee(uint256 minExecutionFee);
    event UpdateMinPurchaseTokenAmountUsd(uint256 minPurchaseTokenAmountUsd);
    event UpdateGov(address gov);
    event UpdateFastPriceFeed(address fastPriceFeed);

    modifier onlyGov() {
        require(msg.sender == gov, "OrderBook: forbidden");
        _;
    }

    modifier onlyFastPriceFeed() {
        require(msg.sender == fastPriceFeed, "OrderBook: forbidden");
        _;
    }

    constructor() public {
        gov = msg.sender;
    }

    function initialize(
        address _router,
        address _vault,
        address _weth,
        address _usdf,
        uint256 _minExecutionFee,
        uint256 _minPurchaseTokenAmountUsd,
        address _fastPriceFeed
    ) external onlyGov {
        require(!isInitialized, "OrderBook: already initialized");
        isInitialized = true;

        router = _router;
        vault = _vault;
        weth = _weth;
        usdf = _usdf;
        minExecutionFee = _minExecutionFee;
        minPurchaseTokenAmountUsd = _minPurchaseTokenAmountUsd;
        fastPriceFeed = _fastPriceFeed;

        emit Initialize(
            _router,
            _vault,
            _weth,
            _usdf,
            _minExecutionFee,
            _minPurchaseTokenAmountUsd,
            _fastPriceFeed
        );
    }

    receive() external payable {
        require(msg.sender == weth, "OrderBook: invalid sender");
    }

    function setMinExecutionFee(uint256 _minExecutionFee) external onlyGov {
        minExecutionFee = _minExecutionFee;

        emit UpdateMinExecutionFee(_minExecutionFee);
    }

    function setMinPurchaseTokenAmountUsd(
        uint256 _minPurchaseTokenAmountUsd
    ) external onlyGov {
        minPurchaseTokenAmountUsd = _minPurchaseTokenAmountUsd;

        emit UpdateMinPurchaseTokenAmountUsd(_minPurchaseTokenAmountUsd);
    }

    function setGov(address _gov) external onlyGov {
        gov = _gov;

        emit UpdateGov(_gov);
    }

    function setFastPriceFeed(address _fastPriceFeed) external onlyGov {
        fastPriceFeed = _fastPriceFeed;

        emit UpdateFastPriceFeed(_fastPriceFeed);
    }

    function validatePositionOrderPrice(
        bool _triggerAboveThreshold,
        uint256 _triggerPrice,
        address _indexToken,
        bool _maximizePrice,
        bool _raise
    ) public view returns (uint256, bool) {
        uint256 currentPrice = _maximizePrice
            ? IVault(vault).getMaxPrice(_indexToken)
            : IVault(vault).getMinPrice(_indexToken);
        bool isPriceValid = _triggerAboveThreshold
            ? currentPrice > _triggerPrice
            : currentPrice < _triggerPrice;
        if (_raise) {
            require(isPriceValid, "OrderBook: invalid price for execution");
        }
        return (currentPrice, isPriceValid);
    }

    function getTrailingStopOrder(
        address _account,
        uint256 _orderIndex
    )
        public
        view
        override
        returns (
            address collateralToken,
            uint256 collateralDelta,
            address indexToken,
            uint256 sizeDelta,
            bool isLong,
            uint256 triggerPrice,
            bool triggerAboveThreshold,
            uint256 executionFee,
            uint256 trailingBPS
        )
    {
        TrailingStopOrder memory order = trailingStopOrders[_account][
            _orderIndex
        ];
        return (
            order.collateralToken,
            order.collateralDelta,
            order.indexToken,
            order.sizeDelta,
            order.isLong,
            order.triggerPrice,
            order.triggerAboveThreshold,
            order.executionFee,
            order.trailingBPS
        );
    }

    function createTrailingStopOrder(
        address _indexToken,
        uint256 _sizeDelta,
        address _collateralToken,
        uint256 _collateralDelta,
        bool _isLong,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold,
        uint256 _trailingBPS
    ) external payable nonReentrant {
        _transferInETH();

        require(
            msg.value > minExecutionFee,
            "OrderBook: insufficient execution fee"
        );

        _createTrailingStopOrder(
            msg.sender,
            _collateralToken,
            _collateralDelta,
            _indexToken,
            _sizeDelta,
            _isLong,
            _triggerPrice,
            _triggerAboveThreshold,
            _trailingBPS
        );
    }

    function _createTrailingStopOrder(
        address _account,
        address _collateralToken,
        uint256 _collateralDelta,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold,
        uint256 _trailingBPS
    ) private {
        uint256 _orderIndex = trailingStopOrdersIndex[_account];
        TrailingStopOrder memory order = TrailingStopOrder(
            _account,
            _collateralToken,
            _collateralDelta,
            _indexToken,
            _sizeDelta,
            _isLong,
            _triggerPrice,
            _triggerAboveThreshold,
            msg.value,
            _trailingBPS
        );
        trailingStopOrdersIndex[_account] = _orderIndex.add(1);
        trailingStopOrders[_account][_orderIndex] = order;

        emit CreateTrailingStopOrder(
            _account,
            _orderIndex,
            _collateralToken,
            _collateralDelta,
            _indexToken,
            _sizeDelta,
            _isLong,
            _triggerPrice,
            _triggerAboveThreshold,
            msg.value,
            _trailingBPS
        );
    }

    function updateTrailingStopOrder(
        uint256 _orderIndex,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold,
        uint256 _trailingBPS
    ) external nonReentrant {
        TrailingStopOrder storage order = trailingStopOrders[msg.sender][
            _orderIndex
        ];
        require(order.account != address(0), "OrderBook: non-existent order");

        order.triggerPrice = _triggerPrice;
        order.triggerAboveThreshold = _triggerAboveThreshold;
        order.sizeDelta = _sizeDelta;
        order.collateralDelta = _collateralDelta;
        order.trailingBPS = _trailingBPS;

        emit UpdateTrailingStopOrder(
            msg.sender,
            _orderIndex,
            order.collateralToken,
            _collateralDelta,
            order.indexToken,
            _sizeDelta,
            order.isLong,
            _triggerPrice,
            _triggerAboveThreshold,
            _trailingBPS
        );
    }

    function cancelTrailingStopOrder(uint256 _orderIndex) public nonReentrant {
        TrailingStopOrder memory order = trailingStopOrders[msg.sender][
            _orderIndex
        ];
        require(order.account != address(0), "OrderBook: non-existent order");

        delete trailingStopOrders[msg.sender][_orderIndex];
        _transferOutETH(order.executionFee, msg.sender);

        emit CancelTrailingStopOrder(
            order.account,
            _orderIndex,
            order.collateralToken,
            order.collateralDelta,
            order.indexToken,
            order.sizeDelta,
            order.isLong,
            order.triggerPrice,
            order.triggerAboveThreshold,
            order.executionFee,
            order.trailingBPS
        );
    }

    function executeTrailingStopOrder(
        address _address,
        uint256 _orderIndex,
        address payable _feeReceiver
    ) external  override nonReentrant onlyFastPriceFeed {
        TrailingStopOrder memory order = trailingStopOrders[_address][
            _orderIndex
        ];
        require(order.account != address(0), "OrderBook: non-existent order");

        // decrease long should use min price
        // decrease short should use max price
        (uint256 currentPrice, ) = validatePositionOrderPrice(
            order.triggerAboveThreshold,
            order.triggerPrice,
            order.indexToken,
            !order.isLong,
            true
        );

        delete trailingStopOrders[_address][_orderIndex];

        uint256 amountOut = IRouter(router).pluginDecreasePosition(
            order.account,
            order.collateralToken,
            order.indexToken,
            order.collateralDelta,
            order.sizeDelta,
            order.isLong,
            address(this)
        );

        // transfer released collateral to user
        if (order.collateralToken == weth) {
            _transferOutETH(amountOut, payable(order.account));
        } else {
            IERC20(order.collateralToken).safeTransfer(
                order.account,
                amountOut
            );
        }

        // pay executor
        _transferOutETH(order.executionFee, _feeReceiver);

        emit ExecuteTrailingStopOrder(
            order.account,
            _orderIndex,
            order.collateralToken,
            order.collateralDelta,
            order.indexToken,
            order.sizeDelta,
            order.isLong,
            order.triggerPrice,
            order.triggerAboveThreshold,
            order.executionFee,
            currentPrice,
            order.trailingBPS
        );
    }

    function _transferInETH() private {
        if (msg.value != 0) {
            IWETH(weth).deposit{value: msg.value}();
        }
    }

    function _transferOutETH(
        uint256 _amountOut,
        address payable _receiver
    ) private {
        IWETH(weth).withdraw(_amountOut);
        _receiver.sendValue(_amountOut);
    }

}


// https://goerli.etherscan.io/tx/0x64c3b883de892be1bf03738cbc4007fb6a1167196a5fb98f8d4fcbccae0800c1