//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DecentalizedStableCoin} from "./DecentalizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "forge-std/console.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author Mudit Sarda
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token = $1 peg
 * The stablecoin has the following properties:
 *  1. Exogenous collateral
 *  2. Dollar pegged
 *  3. Algorithmically stable
 *
 * It is similar to DAI, if DAI had no governance, no fees, and was only backed by WETH and WBTC
 *
 * Our DSC system should always be "over-collateralize". At no point, should the value of all collateral <= the $ backed value
 * of all DSC.
 *
 * @notice This contract is the core of the DSC System. It handles all the logic for mining and redeeming DSC, as well as depositing and withdrawing collateral
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system
 */
contract DSCEngine is ReentrancyGuard {
    ////////////////
    // errors //////
    ////////////////
    error DSCEngine__NeedMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedAddressMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor();
    error DSCEngine_MintFailed();
    error DSCEngine__healthFactorOk();
    error DSCEngine__HealthfactorNotImproved();

    ////////////////
    // types ///////
    ////////////////
    using OracleLib for AggregatorV3Interface;

    ///////////////////////
    // state variables ////
    ///////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralised
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;

    mapping(address token => address priceFeed) private s_priceFeed;
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentalizedStableCoin private immutable i_dsc;

    ///////////////////////
    // events /////////////
    ///////////////////////
    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );
    event collateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed token,
        uint256 amount
    );

    ////////////////
    // modifier ////
    ////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeed[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    /////////////////
    // functions ////
    /////////////////
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses, // all price feeds will be USD price feed to get total collateral value in USD
        address dscAddress
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressAndPriceFeedAddressMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeed[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentalizedStableCoin(dscAddress);
    }

    //////////////////////////
    // external functions ////
    //////////////////////////
    /**
     *
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of DSC to mint
     * @notice This function will deposit your collateral and mint your DSC tokens in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice follows CEI
     *
     * @param tokenCollateralAddress the address of the token to deposit as collateral
     * @param amountCollateral the amount of collateral to deposit
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][
            tokenCollateralAddress
        ] += amountCollateral;
        emit CollateralDeposited(
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     *
     * @param tokenCollateralAddress address of token to burn as collateral
     * @param amountCollateral amouunt of collateral to burn
     * @param amountDscToBurn amount of DSC tokens to burn
     *
     * @notice This function burns the DSC token and then redeem the collateral in one transaction.
     * @notice don't need to check for zero amount and health factor breaking as both the functions individually do it
     */
    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    // in order to redeem collateral
    // 1. health factor must be greater than 1 after redeeming collateral
    // here we transfer the tokens first and the check for the healthfactor because else it will be too gas expensive
    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public moreThanZero(amountCollateral) nonReentrant {
        _redeemCollateral(
            tokenCollateralAddress,
            amountCollateral,
            msg.sender,
            msg.sender
        );
        _revertHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follows CEI
     * @param amountDscToMint the amount of decentralized stable coin to mint
     * @notice they must have more collateral value than the minimum threshold
     */
    function mintDsc(
        uint256 amountDscToMint
    ) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // if they have minted too much, eg $150 DSC, $100 ETH
        _revertHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine_MintFailed();
        }
    }

    // burning dsc will not break the health factor as dsc represents debt, repaying it will never break health factor
    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertHealthFactorIsBroken(msg.sender); // will probably never be needed
    }

    // if someone nears undercollateralization, we need someone to liquidate them.
    // if someone liquidates a position of undercolaateralization, he will get paid.
    // $100 ETH -> $50 DSC
    // tanks to $20 ETH -> $50 DSC(now the DSC is no longer worth $1!!)
    // as someone's collateral falls below the threshold of 200%(eg. as $100 ETH -> $50 DSC falls to $75 -> $50 DSC),
    // someone will be incentivised to liquidate them(i.e. pay back their $50 DSC to the system) and can take home $75 ETH.
    /**
     *
     * @param collateral the erc20 collateral to liquidate the user
     * @param user the person with broken health factor. their health factor should be below MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you wish to burn(i.e. pay back user's debt) to improve user's health factor
     *
     * @notice you can partially liquidate a user
     * @notice you will get a liquidation bonus for taking the user's funds
     * @notice this function working assumes that the system is roughly 200% overcollateralized
     * @notice a known bug is when the system is 100% or less collateralized, we won't be able to incentivize the liquidators
     */
    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__healthFactorOk();
        }

        // bad use: $140 ETH -> $100 DSC
        // debtToCover = $100
        // $100 DSC = ?? ETH
        // 1 ETH = $3500
        // 100/3500 = 0.028 ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            collateral,
            debtToCover
        );

        // additionally we give 10% bonus
        // so we give the liquidators $110 of WETH for 100 DSC
        // we should have a way to sweep the extra amounts in a treasury
        // 0.028 * 10/100 = 0.0028 ETH
        // 0.028 + 0.0028 = 0.0308 ETH
        uint256 bonusCollateral = ((tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION);
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered +
            bonusCollateral;

        // redeem the collateral
        _redeemCollateral(
            collateral,
            totalCollateralToRedeem,
            user,
            msg.sender
        );

        // burn the DSC
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        console.log(endingUserHealthFactor);

        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthfactorNotImproved();
        }

        _revertHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    //////////////////////////////////////
    // private and internal functions ////
    //////////////////////////////////////

    /**
     * @dev low lovel internal function, do not call if the function s=does not check for the health factor being broken
     */
    function _burnDsc(
        uint256 amountDscToBurn,
        address onBehalfOf,
        address dscFrom
    ) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(
            dscFrom,
            address(this),
            amountDscToBurn
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        address from,
        address to
    ) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit collateralRedeemed(
            from,
            to,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transfer(
            to,
            amountCollateral
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(
        address user
    )
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    // returns how close to liquidity a user is. If below 1, then can be liquidated.
    function _healthFactor(address user) private view returns (uint256) {
        // 1. total collateral value in USD
        // 2. total DSC minted
        (
            uint256 totalDscMinted,
            uint256 totalCollateralValueInUsd
        ) = _getAccountInformation(user);
        // collateral of value $1000 and $100 DSC. 1000*50 = 50000/100 = 500(need double collateral than dsc). 500/100 > 1
        uint256 collateralAdjustedForThreshold = (totalCollateralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    // 1. check if they have enough collateral(i.e. health factor)
    // 2. revert if they don't
    function _revertHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor();
        }
    }

    //////////////////////////////////////////
    // public and external view functions ////
    //////////////////////////////////////////

    // through this function we find how much ETH(collateral) should the liquidator pay to cover the debt(which is in DSC)
    // eg. through priceFeed we get info like $3500/ETH. If I want to repay a debt of $100, I pay (100/3500)ETH
    function getTokenAmountFromUsd(
        address token,
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeed[token]
        );
        (, int256 price, , , ) = priceFeed.StaleCheckLatestRoundData();
        return
            (usdAmountInWei * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(
        address user
    ) public view returns (uint256) {
        // loop through each collateral token, get the amounts they have deposited, map it to the prices to get usd value
        uint256 totalCollateralValueInUsd = 0;
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeed[token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        // if 1 ETH = $1000
        // we will get value 1000*1e8(because ETH/USD and BTC/USD priceFeeds have 8 decimal places)
        // if amount = 1000
        // total value in usd = (1000 * 1e8) * (1000 * 1e18) because amount will be in wei
        // hence multilply (1000*1e8) with (1e10) and then divide (1e18) from the total answer
        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getCollateralDeposited(
        address user,
        address tokenAsCollateral
    ) public view returns (uint256) {
        return s_collateralDeposited[user][tokenAsCollateral];
    }

    function getAdditionalPrecision() public pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecision() public pure returns (uint256) {
        return PRECISION;
    }

    function getCollateral(
        address user,
        address token
    ) public view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getDscMinted(address user) public view returns (uint256) {
        return s_DSCMinted[user];
    }

    function getCollateralTokens() public view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(
        address user,
        address token
    ) public view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getAccountInformation(
        address user
    )
        public
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        return _getAccountInformation(user);
    }

    function getCollateralTokenPriceFeed(
        address token
    ) external view returns (address) {
        return s_priceFeed[token];
    }
}
