// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
//import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {console} from "forge-std/console.sol";
import {OracleLib, AggregatorV3Interface} from "./Libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author Julien Terrier (Based on the work and lesson made by Patrick Collins)
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 *
 */
contract DSCEngine is ReentrancyGuard {
    /////////////
    // Errors //
    ////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenNotAllowed(address token);
    error DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthOk();
    error DSCEngine__HealthFactorNotImprove();

    ///////////////////
    // Types
    ///////////////////
    using OracleLib for AggregatorV3Interface;

    /////////////////////
    // State Variables //
    /////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // It means a 10% bonus

    DecentralizedStableCoin private immutable i_dsc;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;

    address[] private s_collateralTokens;

    /////////////
    // Events //
    ////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    ////////////////
    // Modifiers //
    ///////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed(token);
        }
        _;
    }

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
        }
        // These feeds will be the USD pairs
        // For example ETH / USD or MKR / USD
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ///////////////
    // Functions //
    ///////////////

    ////////////////////////
    // External Functions //
    ///////////////////////

    /*
     * @param _tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param _amountCollateral: The amount of collateral you're depositing
     * @param _amountDscToMint: The amount of DSC you want to mint
     * @notice This function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDSC(
        address _tokenCollateralAddress,
        uint256 _collateralAmount,
        uint256 _amountDscToMint
    ) external {
        // Deposit collateral
        depositCollateral(_tokenCollateralAddress, _collateralAmount);
        // Mint DSC
        mintDSC(_amountDscToMint);
    }

    /*
     * @param _tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param _collateralAmount: The amount of collateral you're depositing
     */
    function depositCollateral(address _tokenCollateralAddress, uint256 _collateralAmount)
        public
        moreThanZero(_collateralAmount)
        isAllowedToken(_tokenCollateralAddress)
        nonReentrant
    {
        // Deposit collateral
        s_collateralDeposited[msg.sender][_tokenCollateralAddress] += _collateralAmount;
        emit CollateralDeposited(msg.sender, _tokenCollateralAddress, _collateralAmount);
        bool success = IERC20(_tokenCollateralAddress).transferFrom(msg.sender, address(this), _collateralAmount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*
     * @param _tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param _collateralAmount: The amount of collateral you're depositing
     * @param _amountDscToBurn: The amount of DSC you want to burn
     * @notice This function will withdraw your collateral and burn DSC in one transaction
     */
    function redeemCollateralForDSC(
        address _tokenCollateralAddress,
        uint256 _collateralAmount,
        uint256 _amountDscToBurn
    ) external {
        burnDSC(_amountDscToBurn);
        redeemCollateral(_tokenCollateralAddress, _collateralAmount);
        // RedeemCollateral already checks health factor
    }

    // In order to redeem collateral:
    // 1. Health factor must be over 1 AFTER collateral pulled
    // DRY: Don't reapeat yourself
    // CEI: Check, Effects, Interactions
    function redeemCollateral(address _tokenCollateralAddress, uint256 _collateralAmount)
        public
        moreThanZero(_collateralAmount)
        nonReentrant
    {
        _redeemCollateral(_tokenCollateralAddress, _collateralAmount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //////////////////////
    // Public Functions //
    /////////////////////
    /*
     * @param amountDscToMint: The amount of DSC you want to mint
     * You can only mint DSC if you hav enough collateral
     */
    function mintDSC(uint256 _amountDscToMint) public moreThanZero(_amountDscToMint) nonReentrant {
        // Mint DSC
        s_dscMinted[msg.sender] += _amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, _amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDSC(uint256 _dscAmount) public moreThanZero(_dscAmount) {
        // Burn DSC
        _burnDsc(_dscAmount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I don't thing this would ever hit
    }

    /*
     * @param collateral: The ERC20 token address of the collateral you're using to make the protocol solvent again.
     * This is collateral that you're going to take from the user who is insolvent.
     * In return, you have to burn your DSC to pay off their debt, but you don't pay off your own.
     * @param user: The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
     * @param debtToCover: The amount of DSC you want to burn to cover the user's debt.
     *
     * @notice: You can partially liquidate a user.
     * @notice: You will get a 10% LIQUIDATION_BONUS for taking the users funds.
    * @notice: This function working assumes that the protocol will be roughly 150% overcollateralized in order for this
    to work.
    * @notice: A known bug would be if the protocol was only 100% collateralized, we wouldn't be able to liquidate
    anyone.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(address _collateral, address _user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // Need to check health factor of user
        uint256 startingUserHealthFactor = _healthFactor(_user);
        console.log("Starting user health factor: ", startingUserHealthFactor);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthOk();
        }
        // We want to burn their DSC "debt"
        // And take their collateral
        // Bad user: $140 ETH, $100 DSC
        // Debt to cover: $100
        // $100 of DSC = how much ETH ????
        // Liquidate DSC
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(_collateral, debtToCover);
        console.log("Token Amount From Debt to cover: ", tokenAmountFromDebtCovered);
        // And give them 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into treasury

        // 0.05 ETH * 0.1 = 0.005. Getting 0.055 ETH
        // uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        // uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        // _redeemCollateral(_collateral, totalCollateralToRedeem, _user, msg.sender);

        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        console.log("Collateral bonus: ", bonusCollateral);
        // Burn DSC equal to debtToCover
        // Figure out how much collateral to recover based on how much burnt
        _redeemCollateral(_collateral, tokenAmountFromDebtCovered + bonusCollateral, _user, msg.sender);
        console.log("Collateral redeemed: ", tokenAmountFromDebtCovered + bonusCollateral);
        console.log("Debt to cover: ", debtToCover);
        // We need to burn the DSC
        _burnDsc(debtToCover, msg.sender, _user);

        uint256 endingUserHealthFactor = _healthFactor(_user);
        console.log("Ending user health factor: ", endingUserHealthFactor);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImprove();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view returns (uint256) {
        // Calculate health factor
    }

    ///////////////////////
    // Private Functions //
    ///////////////////////

    function _redeemCollateral(address _tokenCollateralAddress, uint256 _amountCollateral, address _from, address _to)
        private
    {
        s_collateralDeposited[_from][_tokenCollateralAddress] -= _amountCollateral;
        emit CollateralRedeemed(_from, _to, _tokenCollateralAddress, _amountCollateral);
        bool success = IERC20(_tokenCollateralAddress).transfer(_to, _amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*
     * @dev low-level internal function, do not call unless the function calling it is
     * checking for health factors being broken
    */

    // there is a bug (major issue) to find in _burnDsc (write some test)

    function _burnDsc(uint256 _amountDscToBurn, address _onBehalfOf, address _dscFrom) private {
        s_dscMinted[_onBehalfOf] -= _amountDscToBurn;

        bool success = i_dsc.transferFrom(_dscFrom, address(this), _amountDscToBurn);
        // This conditional is hypothetically unreachable
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(_amountDscToBurn);
    }

    //////////////////////////////////
    // Private & Internal Functions //
    /////////////////////////////////

    function _getAccountInformation(address _user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_dscMinted[_user];
        collateralValueInUsd = getAccountCollateralValue(_user);
    }

    /*
     * @notice Returns how close to liquidation a user is
     * If user goes below 1, they are liquidated
     * @param _user: The address of the user
     * @return The health factor of the user
     */
    function _healthFactor(address _user) private view returns (uint256) {
        // Calculate health factor
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(_user);
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
        //return (totalDscMinted / collateralValueInUsd);
        //return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address _user) internal view {
        // Revert if health factor is broken
        uint256 userHealthFactor = _healthFactor(_user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    //////////////////////////////////////////////
    // External & Public View & Pure Functions //
    /////////////////////////////////////////////

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getTokenAmountFromUsd(address _token, uint256 _usdAmountInWei) public view returns (uint256) {
        // Get token amount from USD
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[_token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // 1 ETH = 1000 USD
        // The returned value from Chainlink will be 1000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        // We want to have everything in terms of WEI, so we add 10 zeros at the end
        return ((_usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getAccountCollateralValue(address _user) public view returns (uint256 totalCollateralValueInUsd) {
        // Calculate collateral value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            // Calculate collateral value
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[_user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address _token, uint256 _amount) public view returns (uint256) {
        // Get USD value
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[_token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // 1 ETH = 1000 USD
        // The returned value from Chainlink will be 1000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        // We want to have everything in terms of WEI, so we add 10 zeros at the end
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * _amount) / PRECISION;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        return _getAccountInformation(user);
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }
}
