
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title Simplified Vault
 * @notice A simplified ERC4626-compatible vault
 */
contract SimplifiedVault is ERC20, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // Events
    event StrategyAdded(address indexed strategy);
    event StrategyRemoved(address indexed strategy);
    event StrategyReported(
        address indexed strategy,
        uint256 gain,
        uint256 loss,
        uint256 totalDebt,
        uint256 protocolFees
    );
    event UpdateManager(address indexed newManager);
    event DebtUpdated(
        address indexed strategy,
        uint256 currentDebt,
        uint256 newDebt
    );

    // Constants
    uint256 public constant MAX_BPS = 10_000; // 100%
    uint256 public constant SECONDS_PER_YEAR = 365.25 days;
    
    // Immutables
    address public immutable factory;
    IERC20 public immutable asset;

    // Access control
    address public manager;
    
    // Strategy management
    struct StrategyParams {
        uint256 activation;    // When strategy was added
        uint256 lastReport;    // Last report timestamp
        uint256 currentDebt;   // Current debt (assets allocated)
        uint256 maxDebt;       // Maximum debt allowed
    }
    
    mapping(address => StrategyParams) public strategies;
    address[] public activeStrategies;

    // Vault accounting
    uint256 public totalDebt;      // Total assets allocated to strategies
    uint256 public totalIdle;      // Total assets in vault
    uint256 public pricePerShare;  // Current price per share
    
    // Profit management
    uint256 public lastProfitUpdate;
    uint256 public profitUnlockingRate;
    uint256 public fullProfitUnlockDate;
    
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

    /**
     * @notice Initialize the vault
     * @param _asset Underlying asset address
     * @param _name Vault name
     * @param _symbol Vault symbol
     * @param _manager Manager address
     */
    function initialize(
        address _asset,
        string memory _name,
        string memory _symbol,
        address _manager
    ) external onlyFactory {
        require(address(asset) == address(0), "Already initialized");
        require(_asset != address(0), "Invalid asset");
        require(_manager != address(0), "Invalid manager");

        asset = IERC20(_asset);
        manager = _manager;
        
        _mint(address(this), 0); // Initialize ERC20
        _updateName(_name, _symbol);
    }

    /**
     * @notice Deposit assets and mint shares
     * @param assets Amount of assets to deposit
     * @param receiver Address to receive the shares
     * @return shares Amount of shares minted
     */
    function deposit(uint256 assets, address receiver) 
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        require(assets > 0, "Zero assets");
        require(receiver != address(0), "Invalid receiver");

        // Calculate shares to mint
        shares = _convertToShares(assets, Math.Rounding.Down);
        require(shares > 0, "Zero shares");

        // Transfer assets from user
        asset.safeTransferFrom(msg.sender, address(this), assets);
        
        // Update accounting
        totalIdle += assets;
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        // Auto allocate if strategies exist
        _autoAllocate();
    }

    /**
     * @notice Withdraw assets by burning shares
     * @param assets Amount of assets to withdraw
     * @param receiver Address to receive the assets
     * @param owner Owner of the shares
     * @return shares Amount of shares burned
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external nonReentrant returns (uint256 shares) {
        require(assets > 0, "Zero assets");
        require(receiver != address(0), "Invalid receiver");
        
        // Calculate shares to burn
        shares = _convertToShares(assets, Math.Rounding.Up);
        
        // Check allowance if not owner
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // Check if we need to withdraw from strategies
        if (assets > totalIdle) {
            _withdrawFromStrategies(assets - totalIdle);
        }

        // Update accounting
        totalIdle -= assets;
        _burn(owner, shares);

        // Transfer assets
        asset.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /**
     * @notice Add a new strategy
     * @param strategy Strategy address
     * @param maxDebt Maximum debt allowed for strategy
     */
    function addStrategy(address strategy, uint256 maxDebt) 
        external 
        onlyManager 
    {
        require(strategy != address(0), "Invalid strategy");
        require(strategies[strategy].activation == 0, "Strategy exists");
        
        strategies[strategy] = StrategyParams({
            activation: block.timestamp,
            lastReport: block.timestamp,
            currentDebt: 0,
            maxDebt: maxDebt
        });

        activeStrategies.push(strategy);
        emit StrategyAdded(strategy);
    }

    /**
     * @notice Remove a strategy
     * @param strategy Strategy address
     */
    function removeStrategy(address strategy) external onlyManager {
        require(strategies[strategy].currentDebt == 0, "Strategy has debt");
        
        // Remove from active strategies
        for (uint i = 0; i < activeStrategies.length; i++) {
            if (activeStrategies[i] == strategy) {
                activeStrategies[i] = activeStrategies[activeStrategies.length - 1];
                activeStrategies.pop();
                break;
            }
        }

        delete strategies[strategy];
        emit StrategyRemoved(strategy);
    }

    /**
     * @notice Process strategy report
     * @param strategy Strategy address
     */
    function processReport(address strategy) 
        external 
        nonReentrant 
        returns (uint256 gain, uint256 loss) 
    {
        require(strategies[strategy].activation > 0, "Invalid strategy");
        
        // Get strategy's total assets
        uint256 totalAssets = IStrategy(strategy).totalAssets();
        uint256 currentDebt = strategies[strategy].currentDebt;
        
        // Calculate gain/loss
        if (totalAssets > currentDebt) {
            gain = totalAssets - currentDebt;
            // Handle protocol fees
            (uint16 feeBps, address feeRecipient) = IFactory(factory).getProtocolFeeConfig(address(this));
            uint256 protocolFee = (gain * feeBps) / MAX_BPS;
            if (protocolFee > 0) {
                IStrategy(strategy).withdraw(protocolFee, feeRecipient);
                gain -= protocolFee;
            }
            strategies[strategy].currentDebt = currentDebt + gain;
            totalDebt += gain;
        } else {
            loss = currentDebt - totalAssets;
            strategies[strategy].currentDebt = totalAssets;
            totalDebt -= loss;
        }

        strategies[strategy].lastReport = block.timestamp;

        emit StrategyReported(
            strategy,
            gain,
            loss,
            strategies[strategy].currentDebt,
            protocolFee
        );

        return (gain, loss);
    }

    /**
     * @notice Update strategy debt
     * @param strategy Strategy address
     * @param targetDebt Target debt for strategy
     */
    function updateDebt(address strategy, uint256 targetDebt) 
        external 
        onlyManager 
        nonReentrant 
    {
        StrategyParams storage params = strategies[strategy];
        require(params.activation > 0, "Invalid strategy");
        require(targetDebt <= params.maxDebt, "Exceeds max debt");

        uint256 currentDebt = params.currentDebt;
        
        if (targetDebt > currentDebt) {
            // Increase allocation
            uint256 increase = targetDebt - currentDebt;
            require(increase <= totalIdle, "Insufficient idle");
            
            asset.safeApprove(strategy, increase);
            IStrategy(strategy).deposit(increase);
            
            totalIdle -= increase;
            totalDebt += increase;
            params.currentDebt += increase;
        } else {
            // Decrease allocation
            uint256 decrease = currentDebt - targetDebt;
            IStrategy(strategy).withdraw(decrease, address(this));
            
            totalIdle += decrease;
            totalDebt -= decrease;
            params.currentDebt -= decrease;
        }

        emit DebtUpdated(strategy, currentDebt, targetDebt);
    }

    // Internal functions

    function _autoAllocate() internal {
        if (activeStrategies.length == 0 || totalIdle == 0) return;

        // Simple allocation to first strategy
        address strategy = activeStrategies[0];
        StrategyParams storage params = strategies[strategy];
        
        uint256 available = Math.min(
            totalIdle,
            params.maxDebt - params.currentDebt
        );

        if (available > 0) {
            updateDebt(strategy, params.currentDebt + available);
        }
    }

    function _withdrawFromStrategies(uint256 amount) internal {
        uint256 remaining = amount;
        
        for (uint i = 0; i < activeStrategies.length && remaining > 0; i++) {
            address strategy = activeStrategies[i];
            StrategyParams storage params = strategies[strategy];
            
            uint256 toWithdraw = Math.min(remaining, params.currentDebt);
            if (toWithdraw == 0) continue;

            IStrategy(strategy).withdraw(toWithdraw, address(this));
            
            params.currentDebt -= toWithdraw;
            totalDebt -= toWithdraw;
            remaining -= toWithdraw;
        }

        require(remaining == 0, "Insufficient liquidity");
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding)
        internal
        view
        returns (uint256)
    {
        uint256 supply = totalSupply();
        
        if (supply == 0) {
            return assets;
        }
        
        uint256 totalAssets = totalIdle + totalDebt;
        return assets.mulDiv(supply, totalAssets, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding)
        internal
        view
        returns (uint256)
    {
        uint256 supply = totalSupply();
        
        if (supply == 0) {
            return shares;
        }
        
        uint256 totalAssets = totalIdle + totalDebt;
        return shares.mulDiv(totalAssets, supply, rounding);
    }

    function _updateName(string memory _name, string memory _symbol) internal {
        require(bytes(_name).length > 0, "Empty name");
        require(bytes(_symbol).length > 0, "Empty symbol");
        
        // Update ERC20 name and symbol
        // Note: This requires custom ERC20 implementation that allows name updates
        name = _name;
        symbol = _symbol;
    }

    // View functions

    function totalAssets() public view returns (uint256) {
        return totalIdle + totalDebt;
    }

    function getActiveStrategies() external view returns (address[] memory) {
        return activeStrategies;
    }

    function maxDeposit(address) external view returns (uint256) {
        if (paused()) return 0;
        return type(uint256).max;
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        return _convertToAssets(balanceOf(owner), Math.Rounding.Down);
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
}

interface IStrategy {
    function totalAssets() external view returns (uint256);
    function deposit(uint256 assets) external returns (uint256);
    function withdraw(uint256 assets, address receiver) external returns (uint256);
}

interface IFactory {
    function getProtocolFeeConfig(address vault) external view returns (uint16 feeBps, address recipient);
}
