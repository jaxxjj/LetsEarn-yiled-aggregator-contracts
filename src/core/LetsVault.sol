// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {ILetsVault} from "../interfaces/ILetsVault.sol";
import {ITokenizedStrategy} from "../interfaces/ITokenizedStrategy.sol";
/**
 * @title Simplified Vault
 * @notice A simplified ERC4626-compatible vault
 */

contract LetsVault is ILetsVault, ERC20, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // Constants
    uint256 public constant MAX_BPS = 10_000; // 100%
    uint256 public constant SECONDS_PER_YEAR = 365.25 days;
    uint256 public constant REPORT_INTERVAL = 29 days;

    // Immutables
    address public factory;
    IERC20 public underlying;

    // Access control
    address public manager;

    // Strategy management
    struct StrategyParams {
        uint256 activation; // When strategy was added
        uint256 lastReport; // Last report timestamp
        uint256 currentDebt; // Current debt (assets allocated)
        uint256 maxDebt; // Maximum debt allowed
    }

    mapping(address => StrategyParams) private _strategies;
    address[] private _activeStrategies;

    // Vault accounting
    uint256 private _totalDebt; // Total assets allocated to strategies
    uint256 private _totalIdle; // Total assets in vault
    uint256 public pricePerShare; // Current price per share

    // Profit management
    uint256 public lastProfitUpdate;
    uint256 public profitUnlockingRate;
    uint256 public fullProfitUnlockDate;

    // Storage for name/symbol
    string private _name;
    string private _symbol;

    modifier onlyManager() {
        require(msg.sender == manager, "Not manager");
        _;
    }

    modifier onlyFactory() {
        require(msg.sender == factory, "Not factory");
        _;
    }

    constructor() ERC20("", "") {
        factory = msg.sender;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /**
     * @notice Initialize the vault
     * @param asset_ Underlying asset address
     * @param name_ Vault name
     * @param symbol_ Vault symbol
     * @param manager_ Manager address
     */
    function initialize(address asset_, string memory name_, string memory symbol_, address manager_)
        external
        override
    {
        require(address(underlying) == address(0), "Already initialized");
        require(asset_ != address(0), "Invalid asset");
        require(manager_ != address(0), "Invalid manager");

        factory = msg.sender;

        underlying = IERC20(asset_);
        manager = manager_;

        _name = name_;
        _symbol = symbol_;
    }

    /**
     * @notice Deposit assets and mint shares
     * @param assets Amount of assets to deposit
     * @param receiver Address to receive the shares
     * @return shares Amount of shares minted
     */
    function deposit(uint256 assets, address receiver) external nonReentrant whenNotPaused returns (uint256 shares) {
        require(assets > 0, "Zero assets");
        require(receiver != address(0), "Invalid receiver");

        shares = _convertToShares(assets, Math.Rounding.Floor);
        require(shares > 0, "Zero shares");

        underlying.safeTransferFrom(msg.sender, address(this), assets);

        _totalIdle += assets;
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        _autoAllocate();
    }

    /**
     * @notice Withdraw assets by burning shares
     * @param assets Amount of assets to withdraw
     * @param receiver Address to receive the assets
     * @param owner Owner of the shares
     * @return shares Amount of shares burned
     */
    function withdraw(uint256 assets, address receiver, address owner) external nonReentrant returns (uint256 shares) {
        require(assets > 0, "Zero assets");
        require(receiver != address(0), "Invalid receiver");

        shares = _convertToShares(assets, Math.Rounding.Ceil);

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        if (assets > _totalIdle) {
            _withdrawFromStrategies(assets - _totalIdle);
        }

        _totalIdle -= assets;
        _burn(owner, shares);

        underlying.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /**
     * @notice Add a new strategy
     * @param strategy Strategy address
     * @param maxDebt Maximum debt allowed for strategy
     */
    function addStrategy(address strategy, uint256 maxDebt) external onlyManager {
        require(strategy != address(0), "Invalid strategy");
        require(_strategies[strategy].activation == 0, "Strategy exists");

        _strategies[strategy] =
            StrategyParams({activation: block.timestamp, lastReport: block.timestamp, currentDebt: 0, maxDebt: maxDebt});

        _activeStrategies.push(strategy);
        emit StrategyAdded(strategy);
    }

    /**
     * @notice Remove a strategy
     * @param strategy Strategy address
     */
    function removeStrategy(address strategy) external onlyManager {
        require(_strategies[strategy].currentDebt == 0, "Strategy has debt");

        for (uint256 i = 0; i < _activeStrategies.length; i++) {
            if (_activeStrategies[i] == strategy) {
                _activeStrategies[i] = _activeStrategies[_activeStrategies.length - 1];
                _activeStrategies.pop();
                break;
            }
        }

        delete _strategies[strategy];
        emit StrategyRemoved(strategy);
    }

    /**
     * @notice Process strategy report
     * @param strategy Strategy address
     */
    function processReport(address strategy) external nonReentrant returns (uint256 gain, uint256 loss) {
        require(_strategies[strategy].activation > 0, "Invalid strategy");
        require(_strategies[strategy].lastReport + REPORT_INTERVAL < block.timestamp, "Report already processed");

        // Get report from strategy
        (gain, loss) = ITokenizedStrategy(strategy).report();

        // Handle protocol fees on gain
        if (gain > 0) {
            (uint16 feeBps, address feeRecipient) = IFactory(factory).getProtocolFeeConfig(address(this));
            uint256 protocolFee = (gain * feeBps) / MAX_BPS;

            if (protocolFee > 0) {
                ITokenizedStrategy(strategy).withdraw(protocolFee, feeRecipient);
                gain -= protocolFee;
            }

            _strategies[strategy].currentDebt += gain;
            _totalDebt += gain;
        }

        if (loss > 0) {
            _strategies[strategy].currentDebt -= loss;
            _totalDebt -= loss;
        }

        _strategies[strategy].lastReport = block.timestamp;

        emit StrategyReported(strategy, gain, loss, _strategies[strategy].currentDebt, 0);

        return (gain, loss);
    }

    /**
     * @notice Update strategy debt
     * @param strategy Strategy address
     * @param targetDebt Target debt for strategy
     */
    function updateDebt(address strategy, uint256 targetDebt) external onlyManager nonReentrant {
        _updateDebt(strategy, targetDebt);
    }

    // Internal functions

    function _updateDebt(address strategy, uint256 targetDebt) internal {
        StrategyParams storage params = _strategies[strategy];
        require(params.activation > 0, "Invalid strategy");
        require(targetDebt <= params.maxDebt, "Exceeds max debt");

        uint256 currentDebt = params.currentDebt;

        if (targetDebt > currentDebt) {
            uint256 increase = targetDebt - currentDebt;
            require(increase <= _totalIdle, "Insufficient idle");

            underlying.safeIncreaseAllowance(strategy, increase);
            ITokenizedStrategy(strategy).deposit(increase);

            _totalIdle -= increase;
            _totalDebt += increase;
            params.currentDebt += increase;
        } else {
            uint256 decrease = currentDebt - targetDebt;
            ITokenizedStrategy(strategy).withdraw(decrease, address(this));

            _totalIdle += decrease;
            _totalDebt -= decrease;
            params.currentDebt -= decrease;
        }

        emit DebtUpdated(strategy, currentDebt, targetDebt);
    }

    function _autoAllocate() internal {
        if (_activeStrategies.length == 0 || _totalIdle == 0) return;

        address strategy = _activeStrategies[0];
        StrategyParams storage params = _strategies[strategy];

        uint256 available = Math.min(_totalIdle, params.maxDebt - params.currentDebt);

        if (available > 0) {
            _updateDebt(strategy, params.currentDebt + available);
        }
    }

    function _withdrawFromStrategies(uint256 amount) internal {
        uint256 remaining = amount;

        for (uint256 i = 0; i < _activeStrategies.length && remaining > 0; i++) {
            address strategy = _activeStrategies[i];
            StrategyParams storage params = _strategies[strategy];

            uint256 toWithdraw = Math.min(remaining, params.currentDebt);
            if (toWithdraw == 0) continue;

            ITokenizedStrategy(strategy).withdraw(toWithdraw, address(this));

            params.currentDebt -= toWithdraw;
            _totalDebt -= toWithdraw;
            remaining -= toWithdraw;
        }

        require(remaining == 0, "Insufficient liquidity");
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        uint256 supply = totalSupply();

        if (supply == 0) {
            return assets;
        }

        uint256 totalAUM = _totalIdle + _totalDebt;
        return assets.mulDiv(supply, totalAUM, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        uint256 supply = totalSupply();

        if (supply == 0) {
            return shares;
        }

        uint256 totalAUM = _totalIdle + _totalDebt;
        return shares.mulDiv(totalAUM, supply, rounding);
    }

    // Implement any missing interface functions
    function asset() public view override returns (address) {
        return address(underlying);
    }

    // Emergency functions

    function pause() external onlyManager {
        _pause();
    }

    function unpause() external onlyManager {
        _unpause();
    }

    function setManager(address newManager) external onlyManager {
        require(newManager != address(0), "Invalid manager");
        manager = newManager;
        emit UpdateManager(newManager);
    }

    // Make internal conversion functions public to match interface
    function convertToShares(uint256 assets) public view override returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    // Add missing redeem function
    function redeem(uint256 shares, address receiver, address owner) external nonReentrant returns (uint256 assets) {
        require(shares > 0, "Zero shares");
        require(receiver != address(0), "Invalid receiver");

        assets = _convertToAssets(shares, Math.Rounding.Floor);

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        if (assets > _totalIdle) {
            _withdrawFromStrategies(assets - _totalIdle);
        }

        _totalIdle -= assets;
        _burn(owner, shares);

        underlying.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    // Make view functions public to match interface
    function totalDebt() public view override returns (uint256) {
        return _totalDebt;
    }

    function totalIdle() public view override returns (uint256) {
        return _totalIdle;
    }

    // Add missing strategies view function
    function strategies(address strategy)
        external
        view
        override
        returns (uint256 activation, uint256 lastReport, uint256 currentDebt, uint256 maxDebt)
    {
        StrategyParams storage params = _strategies[strategy];
        return (params.activation, params.lastReport, params.currentDebt, params.maxDebt);
    }

    // Make sure all other interface functions are properly implemented
    function getActiveStrategies() external view override returns (address[] memory) {
        return _activeStrategies;
    }

    function totalAssets() public view override returns (uint256) {
        return _totalIdle + _totalDebt;
    }

    function maxDeposit(address) external view override returns (uint256) {
        if (paused()) return 0;
        return type(uint256).max;
    }

    function maxWithdraw(address owner) external view override returns (uint256) {
        return _convertToAssets(balanceOf(owner), Math.Rounding.Floor);
    }
}

interface IFactory {
    function getProtocolFeeConfig(address vault) external view returns (uint16 feeBps, address recipient);
}
