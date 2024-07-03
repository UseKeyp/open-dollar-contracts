// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import {IERC20} from '@openzeppelin/token/ERC20/IERC20.sol';
import {ODProxy} from '@contracts/proxies/ODProxy.sol';
import {IVault721} from '@interfaces/proxies/IVault721.sol';
import {ISAFEEngine} from '@interfaces/ISAFEEngine.sol';
import {IOracleRelayer} from '@interfaces/IOracleRelayer.sol';
import {Math, RAY} from '@libraries/Math.sol';
import {DelayedOracleForTest} from '@test/mocks/DelayedOracleForTest.sol';
import {Common, COLLAT, DEBT, TKN} from '@test/e2e/Common.t.sol';

uint256 constant MINUS_0_5_PERCENT_PER_HOUR = 999_998_607_628_240_588_157_433_861;
uint256 constant DEPOSIT = 135 ether + 1; // 136% collateralized
uint256 constant MINT = 100 ether;
uint256 constant DEFAULT_DEVALUATION = 0.2 ether;
uint256 constant USER_AMOUNT = 1000 ether;

contract E2ELiquidation is Common {
  using Math for uint256;

  uint256 public liquidationCRatio; // RAY
  uint256 public safetyCRatio; // RAY
  uint256 public accumulatedRate; // RAY
  uint256 public liquidationPrice; // RAY

  ISAFEEngine.SAFEEngineCollateralData public cTypeData;
  IOracleRelayer.OracleRelayerCollateralParams public oracleParams;

  IVault721.NFVState public aliceNFV;
  IVault721.NFVState public bobNFV;

  address public aliceProxy;
  address public bobProxy;
  uint256 public initialSystemCoinSupply;

  mapping(address proxy => uint256 safeId) public vaults;

  function setUp() public virtual override {
    super.setUp();
    _refreshCData(TKN);

    aliceProxy = _userVaultSetup(TKN, alice, USER_AMOUNT, 'AliceProxy');
    aliceNFV = vault721.getNfvState(vaults[aliceProxy]);
    _depositCollateralAndGenDebt(TKN, vaults[aliceProxy], DEPOSIT, MINT, aliceProxy);

    bobProxy = _userVaultSetup(TKN, bob, USER_AMOUNT, 'BobProxy');
    bobNFV = vault721.getNfvState(vaults[bobProxy]);
    _depositCollateralAndGenDebt(TKN, vaults[bobProxy], DEPOSIT * 3, MINT * 3, bobProxy);

    initialSystemCoinSupply = systemCoin.totalSupply();

    _refreshCData(TKN);

    _collateralDevaluation(TKN, DEFAULT_DEVALUATION);
    auctionId = liquidationEngine.liquidateSAFE(TKN, aliceNFV.safeHandler);

    vm.prank(bob);
    systemCoin.approve(bobProxy, USER_AMOUNT);
  }

  function testBuyCollateral1() public {
    // CAH holds all 136 ether of collateral after liquidation and before auction
    _logWadCollateralAuctionHouseTokenCollateral(TKN);
    assertEq(safeEngine.tokenCollateral(TKN, address(collateralAuctionHouse[TKN])), DEPOSIT);

    // alice has no collateral after liquidation
    assertEq(safeEngine.tokenCollateral(TKN, aliceNFV.safeHandler), 0);

    // bob's non-deposited collateral balance before collateral auction
    uint256 _externalCollateralBalanceBob = collateral[TKN].balanceOf(bob);

    // alice + bob systemCoin supply
    assertEq(initialSystemCoinSupply, systemCoin.totalSupply());

    // bob to buy alice's liquidated collateral
    _buyCollateral(TKN, auctionId, 0, MINT, bobProxy);

    // alice systemCoin supply burned in collateral auction
    assertEq(systemCoin.totalSupply(), initialSystemCoinSupply - MINT);

    // bob's non-deposited collateral balance after collateral auction
    uint256 _externalCollateralGain = collateral[TKN].balanceOf(bob) - _externalCollateralBalanceBob;
    emit log_named_uint('_externalCollateralGain -------', _externalCollateralGain);

    // coinBalance of accountingEngine: +100 ether
    _logWadAccountingEngineCoinAndDebtBalance();

    // CAH still holds 60 ether of collateral after auction, because more collateral needs to be sold
    _logWadCollateralAuctionHouseTokenCollateral(TKN);
    assertEq(safeEngine.tokenCollateral(TKN, address(collateralAuctionHouse[TKN])), DEPOSIT - _externalCollateralGain);

    // alice's tokenCollateral balance after the auction the initial deposit minus the auctioned collateral
    assertEq(safeEngine.tokenCollateral(TKN, aliceNFV.safeHandler), 0);
  }

  // HELPER FUNCTIONS

  function _collateralDevaluation(bytes32 _cType, uint256 _devaluation) internal {
    uint256 _p = delayedOracle[_cType].read();
    DelayedOracleForTest(address(delayedOracle[_cType])).setPriceAndValidity(_p - _devaluation, true);
    oracleRelayer.updateCollateralPrice(_cType);
    _refreshCData(_cType);
  }

  function _refreshCData(bytes32 _cType) internal {
    cTypeData = safeEngine.cData(_cType);
    liquidationPrice = cTypeData.liquidationPrice;
    accumulatedRate = cTypeData.accumulatedRate;

    oracleParams = oracleRelayer.cParams(_cType);
    liquidationCRatio = oracleParams.liquidationCRatio;
    safetyCRatio = oracleParams.safetyCRatio;
  }

  function _userVaultSetup(
    bytes32 _cType,
    address _user,
    uint256 _amount,
    string memory _name
  ) internal returns (address _proxy) {
    _proxy = _deployOrFind(_user);
    _mintToken(_cType, _user, _amount, _proxy);
    vm.label(_proxy, _name);
    vm.prank(_proxy);
    vaults[_proxy] = safeManager.openSAFE(_cType, _proxy);
  }

  function _mintToken(bytes32 _cType, address _account, uint256 _amount, address _okAccount) internal {
    vm.startPrank(_account);
    deal(address(collateral[_cType]), _account, _amount);
    if (_okAccount != address(0)) {
      IERC20(address(collateral[_cType])).approve(_okAccount, _amount);
    }
    vm.stopPrank();
  }

  function _deployOrFind(address _owner) internal returns (address) {
    address proxy = vault721.getProxy(_owner);
    if (proxy == address(0)) {
      return address(vault721.build(_owner));
    } else {
      return proxy;
    }
  }

  function _depositCollateralAndGenDebt(
    bytes32 _cType,
    uint256 _safeId,
    uint256 _collatAmount,
    uint256 _deltaWad,
    address _proxy
  ) internal {
    vm.startPrank(ODProxy(_proxy).OWNER());
    bytes memory _payload = abi.encodeWithSelector(
      basicActions.lockTokenCollateralAndGenerateDebt.selector,
      address(safeManager),
      address(collateralJoin[_cType]),
      address(coinJoin),
      _safeId,
      _collatAmount,
      _deltaWad
    );
    ODProxy(_proxy).execute(address(basicActions), _payload);
    vm.stopPrank();
  }

  function _buyCollateral(
    bytes32 _cType,
    uint256 _auctionId,
    uint256 _minCollateral,
    uint256 _bid,
    address _proxy
  ) internal {
    vm.startPrank(ODProxy(_proxy).OWNER());
    bytes memory _payload = abi.encodeWithSelector(
      collateralBidActions.buyCollateral.selector,
      address(coinJoin),
      address(collateralJoin[_cType]),
      address(collateralAuctionHouse[_cType]),
      _auctionId,
      _minCollateral,
      _bid
    );
    ODProxy(_proxy).execute(address(collateralBidActions), _payload);
    vm.stopPrank();
  }

  function _logWadAccountingEngineCoinAndDebtBalance() internal {
    emit log_named_uint('_accountingEngineCoinBalance --', safeEngine.coinBalance(address(accountingEngine)) / RAY);
    emit log_named_uint('_accountingEngineDebtBalance --', safeEngine.debtBalance(address(accountingEngine)) / RAY);
  }

  function _logWadCollateralAuctionHouseTokenCollateral(bytes32 _cType) internal {
    emit log_named_uint(
      '_CAH_tokenCollateral ----------', safeEngine.tokenCollateral(_cType, address(collateralAuctionHouse[_cType]))
    );
  }
}
