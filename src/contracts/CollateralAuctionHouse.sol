// SPDX-License-Identifier: GPL-3.0
/// IncreasingDiscountCollateralAuctionHouse.sol

// Copyright (C) 2018 Rain <rainbreak@riseup.net>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity 0.8.19;

import {ISAFEEngine as SAFEEngineLike} from '@interfaces/ISAFEEngine.sol';
import {IOracleRelayer as OracleRelayerLike} from '@interfaces/IOracleRelayer.sol';
import {IOracle as OracleLike} from '@interfaces/IOracle.sol';
import {ILiquidationEngine as LiquidationEngineLike} from '@interfaces/ILiquidationEngine.sol';

import {Authorizable} from '@contracts/utils/Authorizable.sol';

import {Math, RAY, WAD} from '@libraries/Math.sol';

/*
   This thing lets you sell some collateral at an increasing discount in order to instantly recapitalize the system
*/
contract IncreasingDiscountCollateralAuctionHouse is Authorizable {
  using Math for uint256;

  // --- Data ---
  struct Bid {
    // How much collateral is sold in an auction
    uint256 amountToSell; // [wad]
    // Total/max amount of coins to raise
    uint256 amountToRaise; // [rad]
    // Current discount
    uint256 currentDiscount; // [wad]
    // Max possibe discount
    uint256 maxDiscount; // [wad]
    // Rate at which the discount is updated every second
    uint256 perSecondDiscountUpdateRate; // [ray]
    // Last time when the current discount was updated
    uint256 latestDiscountUpdateTime; // [unix timestamp]
    // Deadline after which the discount cannot increase anymore
    uint48 discountIncreaseDeadline; // [unix epoch time]
    // Who (which SAFE) receives leftover collateral that is not sold in the auction; usually the liquidated SAFE
    address forgoneCollateralReceiver;
    // Who receives the coins raised by the auction; usually the accounting engine
    address auctionIncomeRecipient;
  }

  // Bid data for each separate auction
  mapping(uint256 => Bid) public bids;

  // SAFE database
  SAFEEngineLike public safeEngine;
  // Collateral type name
  bytes32 public collateralType;

  // Minimum acceptable bid
  uint256 public minimumBid = 5 * WAD; // [wad]
  // Total length of the auction. Kept to adhere to the same interface as the English auction but redundant
  uint48 public totalAuctionLength = type(uint48).max; // [seconds]
  // Number of auctions started up until now
  uint256 public auctionsStarted = 0;
  // The last read redemption price
  uint256 public lastReadRedemptionPrice;
  // Minimum discount (compared to the system coin's current redemption price) at which collateral is being sold
  uint256 public minDiscount = 0.95e18; // 5% discount                                      // [wad]
  // Maximum discount (compared to the system coin's current redemption price) at which collateral is being sold
  uint256 public maxDiscount = 0.95e18; // 5% discount                                      // [wad]
  // Rate at which the discount will be updated in an auction
  uint256 public perSecondDiscountUpdateRate = RAY; // [ray]
  // Max time over which the discount can be updated
  uint256 public maxDiscountUpdateRateTimeline = 1 hours; // [seconds]
  // Max lower bound deviation that the collateral median can have compared to the FSM price
  uint256 public lowerCollateralMedianDeviation = 0.9e18; // 10% deviation                                    // [wad]
  // Max upper bound deviation that the collateral median can have compared to the FSM price
  uint256 public upperCollateralMedianDeviation = 0.95e18; // 5% deviation                                     // [wad]
  // Max lower bound deviation that the system coin oracle price feed can have compared to the systemCoinOracle price
  uint256 public lowerSystemCoinMedianDeviation = WAD; // 0% deviation                                     // [wad]
  // Max upper bound deviation that the system coin oracle price feed can have compared to the systemCoinOracle price
  uint256 public upperSystemCoinMedianDeviation = WAD; // 0% deviation                                     // [wad]
  // Min deviation for the system coin median result compared to the redemption price in order to take the median into account
  uint256 public minSystemCoinMedianDeviation = 0.999e18; // [wad]

  OracleRelayerLike public oracleRelayer;
  OracleLike public collateralFSM;
  OracleLike public systemCoinOracle;
  LiquidationEngineLike public liquidationEngine;

  bytes32 public constant AUCTION_HOUSE_TYPE = bytes32('COLLATERAL');
  bytes32 public constant AUCTION_TYPE = bytes32('INCREASING_DISCOUNT');

  // --- Events ---
  event StartAuction(
    uint256 id,
    uint256 auctionsStarted,
    uint256 amountToSell,
    uint256 initialBid,
    uint256 indexed amountToRaise,
    uint256 startingDiscount,
    uint256 maxDiscount,
    uint256 perSecondDiscountUpdateRate,
    uint48 discountIncreaseDeadline,
    address indexed forgoneCollateralReceiver,
    address indexed auctionIncomeRecipient
  );
  event ModifyParameters(bytes32 parameter, uint256 data);
  event ModifyParameters(bytes32 parameter, address data);
  event BuyCollateral(uint256 indexed id, uint256 wad, uint256 boughtCollateral);
  event SettleAuction(uint256 indexed id, uint256 leftoverCollateral);
  event TerminateAuctionPrematurely(uint256 indexed id, address sender, uint256 collateralAmount);

  // --- Init ---
  constructor(address _safeEngine, address _liquidationEngine, bytes32 _collateralType) Authorizable(msg.sender) {
    safeEngine = SAFEEngineLike(_safeEngine);
    liquidationEngine = LiquidationEngineLike(_liquidationEngine);
    collateralType = _collateralType;
  }

  // --- Admin ---
  /**
   * @notice Modify an uint256 parameter
   * @param parameter The name of the parameter to modify
   * @param data New value for the parameter
   */
  function modifyParameters(bytes32 parameter, uint256 data) external isAuthorized {
    if (parameter == 'minDiscount') {
      require(data >= maxDiscount && data < WAD, 'IncreasingDiscountCollateralAuctionHouse/invalid-min-discount');
      minDiscount = data;
    } else if (parameter == 'maxDiscount') {
      require(
        (data <= minDiscount && data < WAD) && data > 0, 'IncreasingDiscountCollateralAuctionHouse/invalid-max-discount'
      );
      maxDiscount = data;
    } else if (parameter == 'perSecondDiscountUpdateRate') {
      require(data <= RAY, 'IncreasingDiscountCollateralAuctionHouse/invalid-discount-update-rate');
      perSecondDiscountUpdateRate = data;
    } else if (parameter == 'maxDiscountUpdateRateTimeline') {
      require(
        data > 0 && uint256(type(uint48).max) > block.timestamp + data,
        'IncreasingDiscountCollateralAuctionHouse/invalid-update-rate-time'
      );
      maxDiscountUpdateRateTimeline = data;
    } else if (parameter == 'lowerCollateralMedianDeviation') {
      require(data <= WAD, 'IncreasingDiscountCollateralAuctionHouse/invalid-lower-collateral-median-deviation');
      lowerCollateralMedianDeviation = data;
    } else if (parameter == 'upperCollateralMedianDeviation') {
      require(data <= WAD, 'IncreasingDiscountCollateralAuctionHouse/invalid-upper-collateral-median-deviation');
      upperCollateralMedianDeviation = data;
    } else if (parameter == 'lowerSystemCoinMedianDeviation') {
      require(data <= WAD, 'IncreasingDiscountCollateralAuctionHouse/invalid-lower-system-coin-median-deviation');
      lowerSystemCoinMedianDeviation = data;
    } else if (parameter == 'upperSystemCoinMedianDeviation') {
      require(data <= WAD, 'IncreasingDiscountCollateralAuctionHouse/invalid-upper-system-coin-median-deviation');
      upperSystemCoinMedianDeviation = data;
    } else if (parameter == 'minSystemCoinMedianDeviation') {
      minSystemCoinMedianDeviation = data;
    } else if (parameter == 'minimumBid') {
      minimumBid = data;
    } else {
      revert('IncreasingDiscountCollateralAuctionHouse/modify-unrecognized-param');
    }
    emit ModifyParameters(parameter, data);
  }

  /**
   * @notice Modify an addres parameter
   * @param parameter The parameter name
   * @param data New address for the parameter
   */
  function modifyParameters(bytes32 parameter, address data) external isAuthorized {
    if (parameter == 'oracleRelayer') {
      oracleRelayer = OracleRelayerLike(data);
    } else if (parameter == 'collateralFSM') {
      collateralFSM = OracleLike(data);
      // Check that priceSource() is implemented
      collateralFSM.priceSource();
    } else if (parameter == 'systemCoinOracle') {
      systemCoinOracle = OracleLike(data);
    } else if (parameter == 'liquidationEngine') {
      liquidationEngine = LiquidationEngineLike(data);
    } else {
      revert('IncreasingDiscountCollateralAuctionHouse/modify-unrecognized-param');
    }
    emit ModifyParameters(parameter, data);
  }

  // --- Private Auction Utils ---
  /**
   * @notice Get the amount of bought collateral from a specific auction using custom collateral price feeds, a system
   *         coin price feed and a custom discount
   * @param id The ID of the auction to bid in and get collateral from
   * @param collateralFsmPriceFeedValue The collateral price fetched from the FSM
   * @param collateralMedianPriceFeedValue The collateral price fetched from the oracle median
   * @param systemCoinPriceFeedValue The system coin market price fetched from the oracle
   * @param adjustedBid The system coin bid
   * @param customDiscount The discount offered
   */
  function getBoughtCollateral(
    uint256 id,
    uint256 collateralFsmPriceFeedValue,
    uint256 collateralMedianPriceFeedValue,
    uint256 systemCoinPriceFeedValue,
    uint256 adjustedBid,
    uint256 customDiscount
  ) private view returns (uint256) {
    // calculate the collateral price in relation to the latest system coin price and apply the discount
    uint256 discountedCollateralPrice = getDiscountedCollateralPrice(
      collateralFsmPriceFeedValue, collateralMedianPriceFeedValue, systemCoinPriceFeedValue, customDiscount
    );
    // calculate the amount of collateral bought
    uint256 boughtCollateral = adjustedBid.wdiv(discountedCollateralPrice);
    // if the calculated collateral amount exceeds the amount still up for sale, adjust it to the remaining amount
    boughtCollateral = (boughtCollateral > bids[id].amountToSell) ? bids[id].amountToSell : boughtCollateral;

    return boughtCollateral;
  }

  /**
   * @notice Update the discount used in a particular auction
   * @param id The id of the auction to update the discount for
   * @return The newly computed currentDiscount for the targeted auction
   */
  function updateCurrentDiscount(uint256 id) private returns (uint256) {
    // Work directly with storage
    Bid storage auctionBidData = bids[id];
    auctionBidData.currentDiscount = getNextCurrentDiscount(id);
    auctionBidData.latestDiscountUpdateTime = block.timestamp;
    return auctionBidData.currentDiscount;
  }

  // --- Public Auction Utils ---
  /**
   * @notice Fetch the collateral median price (from the oracle, not FSM)
   * @return priceFeed The collateral price from the oracle median; zero if the address of the collateralMedian (as fetched from the FSM) is null
   */
  function getCollateralMedianPrice() public view returns (uint256 priceFeed) {
    // Fetch the collateral median address from the collateral FSM
    address collateralMedian;
    try collateralFSM.priceSource() returns (address median) {
      collateralMedian = median;
    } catch (bytes memory revertReason) {}

    if (collateralMedian == address(0)) return 0;

    // wrapped call toward the collateral median
    try OracleLike(collateralMedian).getResultWithValidity() returns (uint256 price, bool valid) {
      if (valid) {
        priceFeed = uint256(price);
      }
    } catch (bytes memory revertReason) {
      return 0;
    }
  }

  /**
   * @notice Fetch the system coin market price
   * @return priceFeed The system coin market price fetch from the oracle
   */
  function getSystemCoinMarketPrice() public view returns (uint256 priceFeed) {
    if (address(systemCoinOracle) == address(0)) return 0;

    // wrapped call toward the system coin oracle
    try systemCoinOracle.getResultWithValidity() returns (uint256 price, bool valid) {
      if (valid) {
        priceFeed = uint256(price) * 10 ** 9; // scale to RAY
      }
    } catch (bytes memory revertReason) {
      return 0;
    }
  }

  /**
   * @notice Get the smallest possible price that's at max lowerSystemCoinMedianDeviation deviated from the redemption price and at least
   *         minSystemCoinMedianDeviation deviated
   */
  function getSystemCoinFloorDeviatedPrice(uint256 redemptionPrice) public view returns (uint256 floorPrice) {
    uint256 minFloorDeviatedPrice = redemptionPrice.wmul(minSystemCoinMedianDeviation);
    floorPrice = redemptionPrice.wmul(lowerSystemCoinMedianDeviation);
    floorPrice = (floorPrice <= minFloorDeviatedPrice) ? floorPrice : redemptionPrice;
  }

  /**
   * @notice Get the highest possible price that's at max upperSystemCoinMedianDeviation deviated from the redemption price and at least
   *         minSystemCoinMedianDeviation deviated
   */
  function getSystemCoinCeilingDeviatedPrice(uint256 redemptionPrice) public view returns (uint256 ceilingPrice) {
    uint256 minCeilingDeviatedPrice = redemptionPrice.wmul((2 * WAD) - minSystemCoinMedianDeviation);
    ceilingPrice = redemptionPrice.wmul((2 * WAD) - upperSystemCoinMedianDeviation);
    ceilingPrice = (ceilingPrice >= minCeilingDeviatedPrice) ? ceilingPrice : redemptionPrice;
  }

  /**
   * @notice Get the collateral price from the FSM and the final system coin price that will be used when bidding in an auction
   * @param systemCoinRedemptionPrice The system coin redemption price
   * @return The collateral price from the FSM and the final system coin price used for bidding (picking between redemption and market prices)
   */
  function getCollateralFSMAndFinalSystemCoinPrices(uint256 systemCoinRedemptionPrice)
    public
    view
    returns (uint256, uint256)
  {
    require(systemCoinRedemptionPrice > 0, 'IncreasingDiscountCollateralAuctionHouse/invalid-redemption-price-provided');
    (uint256 collateralFsmPriceFeedValue, bool collateralFsmHasValidValue) = collateralFSM.getResultWithValidity();
    if (!collateralFsmHasValidValue) {
      return (0, 0);
    }

    uint256 systemCoinAdjustedPrice = systemCoinRedemptionPrice;
    uint256 systemCoinPriceFeedValue = getSystemCoinMarketPrice();

    if (systemCoinPriceFeedValue > 0) {
      uint256 floorPrice = getSystemCoinFloorDeviatedPrice(systemCoinAdjustedPrice);
      uint256 ceilingPrice = getSystemCoinCeilingDeviatedPrice(systemCoinAdjustedPrice);

      if (uint256(systemCoinPriceFeedValue) < systemCoinAdjustedPrice) {
        systemCoinAdjustedPrice = Math.max(uint256(systemCoinPriceFeedValue), floorPrice);
      } else {
        systemCoinAdjustedPrice = Math.min(uint256(systemCoinPriceFeedValue), ceilingPrice);
      }
    }

    return (uint256(collateralFsmPriceFeedValue), systemCoinAdjustedPrice);
  }

  /**
   * @notice Get the collateral price used in bidding by picking between the raw FSM and the oracle median price and taking into account
   *         deviation limits
   * @param collateralFsmPriceFeedValue The collateral price fetched from the FSM
   * @param collateralMedianPriceFeedValue The collateral price fetched from the median attached to the FSM
   */
  function getFinalBaseCollateralPrice(
    uint256 collateralFsmPriceFeedValue,
    uint256 collateralMedianPriceFeedValue
  ) public view returns (uint256) {
    uint256 floorPrice = collateralFsmPriceFeedValue.wmul(lowerCollateralMedianDeviation);
    uint256 ceilingPrice = collateralFsmPriceFeedValue.wmul((2 * WAD) - upperCollateralMedianDeviation);

    uint256 adjustedMedianPrice =
      (collateralMedianPriceFeedValue == 0) ? collateralFsmPriceFeedValue : collateralMedianPriceFeedValue;

    if (adjustedMedianPrice < collateralFsmPriceFeedValue) {
      return Math.max(adjustedMedianPrice, floorPrice);
    } else {
      return Math.min(adjustedMedianPrice, ceilingPrice);
    }
  }

  /**
   * @notice Get the discounted collateral price (using a custom discount)
   * @param collateralFsmPriceFeedValue The collateral price fetched from the FSM
   * @param collateralMedianPriceFeedValue The collateral price fetched from the oracle median
   * @param systemCoinPriceFeedValue The system coin price fetched from the oracle
   * @param customDiscount The custom discount used to calculate the collateral price offered
   */
  function getDiscountedCollateralPrice(
    uint256 collateralFsmPriceFeedValue,
    uint256 collateralMedianPriceFeedValue,
    uint256 systemCoinPriceFeedValue,
    uint256 customDiscount
  ) public view returns (uint256) {
    // calculate the collateral price in relation to the latest system coin price and apply the discount
    return getFinalBaseCollateralPrice(collateralFsmPriceFeedValue, collateralMedianPriceFeedValue).rdiv(
      systemCoinPriceFeedValue
    ).wmul(customDiscount);
  }

  /**
   * @notice Get the upcoming discount that will be used in a specific auction
   * @param id The ID of the auction to calculate the upcoming discount for
   * @return The upcoming discount that will be used in the targeted auction
   */
  function getNextCurrentDiscount(uint256 id) public view returns (uint256) {
    if (bids[id].forgoneCollateralReceiver == address(0)) return RAY;
    uint256 nextDiscount = bids[id].currentDiscount;

    // If the increase deadline hasn't been passed yet and the current discount is not at or greater than max
    if (uint48(block.timestamp) < bids[id].discountIncreaseDeadline && bids[id].currentDiscount > bids[id].maxDiscount)
    {
      // Calculate the new current discount
      nextDiscount = bids[id].perSecondDiscountUpdateRate.rpow(block.timestamp - bids[id].latestDiscountUpdateTime).rmul(
        bids[id].currentDiscount
      );

      // If the new discount is greater than the max one
      if (nextDiscount <= bids[id].maxDiscount) {
        nextDiscount = bids[id].maxDiscount;
      }
    } else {
      // Determine the conditions when we can instantly set the current discount to max
      bool currentZeroMaxNonZero = bids[id].currentDiscount == 0 && bids[id].maxDiscount > 0;
      bool doneUpdating =
        uint48(block.timestamp) >= bids[id].discountIncreaseDeadline && bids[id].currentDiscount != bids[id].maxDiscount;

      if (currentZeroMaxNonZero || doneUpdating) {
        nextDiscount = bids[id].maxDiscount;
      }
    }

    return nextDiscount;
  }

  /**
   * @notice Get the actual bid that will be used in an auction (taking into account the bidder input)
   * @param id The id of the auction to calculate the adjusted bid for
   * @param wad The initial bid submitted
   * @return Whether the bid is valid or not and the adjusted bid
   */
  function getAdjustedBid(uint256 id, uint256 wad) public view returns (bool, uint256) {
    if ((bids[id].amountToSell == 0 || bids[id].amountToRaise == 0) || (wad == 0 || wad < minimumBid)) {
      return (false, wad);
    }

    uint256 remainingToRaise = bids[id].amountToRaise;

    // bound max amount offered in exchange for collateral
    uint256 adjustedBid = wad;
    if (adjustedBid * RAY > remainingToRaise) {
      adjustedBid = (remainingToRaise / RAY) + 1;
    }

    remainingToRaise = (adjustedBid * RAY > remainingToRaise) ? 0 : bids[id].amountToRaise - (adjustedBid * RAY);
    if (remainingToRaise > 0 && remainingToRaise < RAY) {
      return (false, adjustedBid);
    }

    return (true, adjustedBid);
  }

  // --- Core Auction Logic ---
  /**
   * @notice Start a new collateral auction
   * @param forgoneCollateralReceiver Who receives leftover collateral that is not auctioned
   * @param auctionIncomeRecipient Who receives the amount raised in the auction
   * @param amountToRaise Total amount of coins to raise (rad)
   * @param amountToSell Total amount of collateral available to sell (wad)
   * @param initialBid Unused
   */
  function startAuction(
    address forgoneCollateralReceiver,
    address auctionIncomeRecipient,
    uint256 amountToRaise,
    uint256 amountToSell,
    uint256 initialBid
  ) public isAuthorized returns (uint256 id) {
    require(auctionsStarted < type(uint256).max, 'IncreasingDiscountCollateralAuctionHouse/overflow');
    require(amountToSell > 0, 'IncreasingDiscountCollateralAuctionHouse/no-collateral-for-sale');
    require(amountToRaise > 0, 'IncreasingDiscountCollateralAuctionHouse/nothing-to-raise');
    require(amountToRaise >= RAY, 'IncreasingDiscountCollateralAuctionHouse/dusty-auction');
    id = ++auctionsStarted;

    uint48 discountIncreaseDeadline = uint48(block.timestamp) + uint48(maxDiscountUpdateRateTimeline);

    bids[id].currentDiscount = minDiscount;
    bids[id].maxDiscount = maxDiscount;
    bids[id].perSecondDiscountUpdateRate = perSecondDiscountUpdateRate;
    bids[id].discountIncreaseDeadline = discountIncreaseDeadline;
    bids[id].latestDiscountUpdateTime = block.timestamp;
    bids[id].amountToSell = amountToSell;
    bids[id].forgoneCollateralReceiver = forgoneCollateralReceiver;
    bids[id].auctionIncomeRecipient = auctionIncomeRecipient;
    bids[id].amountToRaise = amountToRaise;

    safeEngine.transferCollateral(collateralType, msg.sender, address(this), amountToSell);

    emit StartAuction(
      id,
      auctionsStarted,
      amountToSell,
      initialBid,
      amountToRaise,
      minDiscount,
      maxDiscount,
      perSecondDiscountUpdateRate,
      discountIncreaseDeadline,
      forgoneCollateralReceiver,
      auctionIncomeRecipient
    );
  }

  /**
   * @notice Calculate how much collateral someone would buy from an auction using the last read redemption price and the old current
   *         discount associated with the auction
   * @param id ID of the auction to buy collateral from
   * @param wad New bid submitted
   */
  function getApproximateCollateralBought(uint256 id, uint256 wad) external view returns (uint256, uint256) {
    if (lastReadRedemptionPrice == 0) return (0, wad);

    (bool validAuctionAndBid, uint256 adjustedBid) = getAdjustedBid(id, wad);
    if (!validAuctionAndBid) {
      return (0, adjustedBid);
    }

    // check that the oracle doesn't return an invalid value
    (uint256 collateralFsmPriceFeedValue, uint256 systemCoinPriceFeedValue) =
      getCollateralFSMAndFinalSystemCoinPrices(lastReadRedemptionPrice);
    if (collateralFsmPriceFeedValue == 0) {
      return (0, adjustedBid);
    }

    return (
      getBoughtCollateral(
        id,
        collateralFsmPriceFeedValue,
        getCollateralMedianPrice(),
        systemCoinPriceFeedValue,
        adjustedBid,
        bids[id].currentDiscount
        ),
      adjustedBid
    );
  }

  /**
   * @notice Calculate how much collateral someone would buy from an auction using the latest redemption price fetched from the
   *         OracleRelayer and the latest updated discount associated with the auction
   * @param id ID of the auction to buy collateral from
   * @param wad New bid submitted
   */
  function getCollateralBought(uint256 id, uint256 wad) external returns (uint256, uint256) {
    (bool validAuctionAndBid, uint256 adjustedBid) = getAdjustedBid(id, wad);
    if (!validAuctionAndBid) {
      return (0, adjustedBid);
    }

    // Read the redemption price
    lastReadRedemptionPrice = oracleRelayer.redemptionPrice();

    // check that the oracle doesn't return an invalid value
    (uint256 collateralFsmPriceFeedValue, uint256 systemCoinPriceFeedValue) =
      getCollateralFSMAndFinalSystemCoinPrices(lastReadRedemptionPrice);
    if (collateralFsmPriceFeedValue == 0) {
      return (0, adjustedBid);
    }

    return (
      getBoughtCollateral(
        id,
        collateralFsmPriceFeedValue,
        getCollateralMedianPrice(),
        systemCoinPriceFeedValue,
        adjustedBid,
        updateCurrentDiscount(id)
        ),
      adjustedBid
    );
  }

  /**
   * @notice Buy collateral from an auction at an increasing discount
   * @param id ID of the auction to buy collateral from
   * @param wad New bid submitted (as a WAD which has 18 decimals)
   */
  function buyCollateral(uint256 id, uint256 wad) external {
    require(
      bids[id].amountToSell > 0 && bids[id].amountToRaise > 0,
      'IncreasingDiscountCollateralAuctionHouse/inexistent-auction'
    );
    require(wad > 0 && wad >= minimumBid, 'IncreasingDiscountCollateralAuctionHouse/invalid-bid');

    // bound max amount offered in exchange for collateral (in case someone offers more than it's necessary)
    uint256 adjustedBid = wad;
    if (adjustedBid * RAY > bids[id].amountToRaise) {
      adjustedBid = (bids[id].amountToRaise / RAY) + 1;
    }

    // Read the redemption price
    lastReadRedemptionPrice = oracleRelayer.redemptionPrice();

    // check that the collateral FSM doesn't return an invalid value
    (uint256 collateralFsmPriceFeedValue, uint256 systemCoinPriceFeedValue) =
      getCollateralFSMAndFinalSystemCoinPrices(lastReadRedemptionPrice);
    require(collateralFsmPriceFeedValue > 0, 'IncreasingDiscountCollateralAuctionHouse/collateral-fsm-invalid-value');

    // get the amount of collateral bought
    uint256 boughtCollateral = getBoughtCollateral(
      id,
      collateralFsmPriceFeedValue,
      getCollateralMedianPrice(),
      systemCoinPriceFeedValue,
      adjustedBid,
      updateCurrentDiscount(id)
    );
    // check that the calculated amount is greater than zero
    require(boughtCollateral > 0, 'IncreasingDiscountCollateralAuctionHouse/null-bought-amount');
    // update the amount of collateral to sell
    bids[id].amountToSell = bids[id].amountToSell - boughtCollateral;

    // update remainingToRaise in case amountToSell is zero (everything has been sold)
    uint256 remainingToRaise = ((wad * RAY >= bids[id].amountToRaise) || (bids[id].amountToSell == 0))
      ? bids[id].amountToRaise
      : bids[id].amountToRaise - (wad * RAY);

    // update leftover amount to raise in the bid struct
    bids[id].amountToRaise =
      (adjustedBid * RAY > bids[id].amountToRaise) ? 0 : bids[id].amountToRaise - (adjustedBid * RAY);

    // check that the remaining amount to raise is either zero or higher than RAY
    require(
      bids[id].amountToRaise == 0 || bids[id].amountToRaise >= RAY,
      'IncreasingDiscountCollateralAuctionHouse/invalid-left-to-raise'
    );

    // transfer the bid to the income recipient and the collateral to the bidder
    safeEngine.transferInternalCoins(msg.sender, bids[id].auctionIncomeRecipient, adjustedBid * RAY);
    safeEngine.transferCollateral(collateralType, address(this), msg.sender, boughtCollateral);

    // Emit the buy event
    emit BuyCollateral(id, adjustedBid, boughtCollateral);

    // Remove coins from the liquidation buffer
    bool soldAll = bids[id].amountToRaise == 0 || bids[id].amountToSell == 0;
    if (soldAll) {
      liquidationEngine.removeCoinsFromAuction(remainingToRaise);
    } else {
      liquidationEngine.removeCoinsFromAuction(adjustedBid * RAY);
    }

    // If the auction raised the whole amount or all collateral was sold,
    // send remaining collateral to the forgone receiver
    if (soldAll) {
      safeEngine.transferCollateral(
        collateralType, address(this), bids[id].forgoneCollateralReceiver, bids[id].amountToSell
      );
      delete bids[id];
      emit SettleAuction(id, bids[id].amountToSell);
    }
  }

  /**
   * @notice Settle/finish an auction
   * @param id ID of the auction to settle
   */
  function settleAuction(uint256 id) external {
    return;
  }

  /**
   * @notice Terminate an auction prematurely. Usually called by Global Settlement.
   * @param id ID of the auction to settle
   */
  function terminateAuctionPrematurely(uint256 id) external isAuthorized {
    require(
      bids[id].amountToSell > 0 && bids[id].amountToRaise > 0,
      'IncreasingDiscountCollateralAuctionHouse/inexistent-auction'
    );
    liquidationEngine.removeCoinsFromAuction(bids[id].amountToRaise);
    safeEngine.transferCollateral(collateralType, address(this), msg.sender, bids[id].amountToSell);
    delete bids[id];
    emit TerminateAuctionPrematurely(id, msg.sender, bids[id].amountToSell);
  }

  // --- Getters ---
  function bidAmount(uint256 id) public view returns (uint256) {
    return 0;
  }

  function remainingAmountToSell(uint256 id) public view returns (uint256) {
    return bids[id].amountToSell;
  }

  function forgoneCollateralReceiver(uint256 id) public view returns (address) {
    return bids[id].forgoneCollateralReceiver;
  }

  function raisedAmount(uint256 id) public view returns (uint256) {
    return 0;
  }

  function amountToRaise(uint256 id) public view returns (uint256) {
    return bids[id].amountToRaise;
  }
}
