# LetsEarn: ultimate easy money earning strategy

## Introduction

yield aggregator for lending, staking, and liquidity provider strategies

## Design Motivation

1. The proliferation of DeFi protocols makes it challenging for most users to evaluate their merits effectively. This evaluation requires expertise in:
   - Smart contract security auditing
   - Protocol metrics analysis
   - Asset distribution patterns
   - Fund flow tracking
   - Yield calculations
   - Fee structures
   - Profit distribution mechanisms

2. LetsEarn aims to provide a transparent, secure, and efficient yield strategy solution on-chain. Users can simply deposit and withdraw funds while the protocol handles all the complexity, offering a high level of abstraction.

## Core Principles

1. Complete transparency in:
   - Fund flows
   - Yield calculations
   - Fee structures
2. Automated periodic yield harvesting and rebalancing for optimal returns

## Development Roadmap

### Phase 1: Core Functionality
Implementation of basic strategies including lending, DEX liquidity provision, and staking, with automated yield harvesting.

### Phase 2: Advanced Strategies
Integration of sophisticated strategies including:
- Leveraged yield farming
- Arbitrage opportunities
- Futures and options trading

### Phase 3: Algorithmic Products
Development of advanced algorithmic products:
- Algorithmic stablecoins
- Bonding mechanisms
- Synthetic derivatives

### Phase 4: Cross-chain Integration
Converting vault tokens to Optimistic Fraud Tokens (OFT) to enable cross-chain yield extraction.

### Phase 5: User Accessibility
Integration of account abstraction to improve accessibility and user experience, making LetsEarn available to a broader audience.

1. lending strategy
    current support: 
    - aave: usdc test block 16773871
2. staking strategy
    current support: 
    - lido
3. liquidity provider strategy
    current support: 
    - uniswap

## Core
1. LetsVaultFactory
The factory is the entry point for creating new vaults:
Deploys new vault instances using minimal proxy pattern for gas efficiency
Manages protocol-wide settings like fees
Key functions:
deployVault(): Creates new vault instances
setProtocolFee(): Updates protocol fee
shutdown(): Emergency shutdown of new vault deployments
2. LetsVault
The vault is the main user-facing contract:
Handles user deposits/withdrawals
Manages multiple strategies
Key features:
ERC4626 compatible (deposit/withdraw interface)
Multi-strategy support
Auto-allocation of funds to strategies
Price per share calculation
Manager role for strategy management
Emergency functions (pause, shutdown)


process: deposit -> convert to shares -> allocate -> rebalance -> withdraw
3. TokenizedStrategy
Base contract for implementing specific yield strategies:
Abstract contract that must be inherited by specific strategy implementations
Key features:
Standardized interface for vault interaction
Performance fee handling
Asset accounting
Virtual functions to implement:
_deployFunds(): Logic for deploying to yield source
_freeFunds(): Logic for withdrawing from yield source
_estimateCurrentAssets(): Calculate current value including yield
Flow of Funds:
User deposits assets into vault
Vault holds assets in totalIdle
Manager allocates assets to strategies
Strategies deploy assets to yield sources
Strategies report profits back to vault
Protocol fees are taken from profits
Remaining profits increase share value for users
This architecture allows for:
Efficient capital allocation across multiple strategies
Risk management through strategy diversification
Scalable deployment of new vaults for different assets
Standardized strategy implementation
Protocol fee generation
Emergency safety measures at multiple levels

4. strategy
 - Each strategy is a separate smart contract
 - Strategy contracts implement specific yield-generating logic
 - Strategies need to be independent, upgradeable units
- Multiple strategies can be active simultaneously

